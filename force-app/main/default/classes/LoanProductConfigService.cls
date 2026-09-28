/**
 * REST service for extracting Loan_Product__c configuration, per-product.
 *
 * Two URL patterns under /v1/loanproductconfig/*:
 *   GET /products
 *     → Lightweight list of all loan products (Id, Name, code, status).
 *       Lets the portal render a selection table without heap pressure.
 *
 *   GET /product/<productId>
 *     → Full configuration graph for a single product:
 *         { loanProduct, relatedObjects: { ... }, fees: { ... } }
 *       Heap stays bounded by one product's footprint, so even maximalist
 *       configurations stay well under the 6 MB Apex limit.
 *
 * The portal stitches per-product responses into a snapshot client-side.
 * Field labels are resolved client-side from generated metadata, so values
 * are emitted raw to keep payloads small.
 */
@RestResource(urlMapping='/v1/loanproductconfig/*')
global with sharing class LoanProductConfigService {

    private static Map<String, Schema.DescribeSObjectResult> describeCache =
        new Map<String, Schema.DescribeSObjectResult>();
    private static Map<String, List<String>> fieldsCache = new Map<String, List<String>>();

    /**
     * Active namespaces for prefix probing. Detected once per request by
     * scanning the global describe for the package's signature objects
     * (Loan_Product__c → core lending package; Holiday_Treatment_Setup__c →
     * clcommon). Falls back to the historical defaults if detection fails.
     *
     * The value is the prefix INCLUDING the trailing double-underscore,
     * e.g. `loan__` or `w22loan__`.
     */
    private static List<String> namespacePrefixes = null;
    private static List<String> getNamespacePrefixes() {
        if (namespacePrefixes != null) return namespacePrefixes;
        namespacePrefixes = new List<String>();
        Map<String, Schema.SObjectType> all = Schema.getGlobalDescribe();
        // Find the core package namespace by looking for any *__Loan_Product__c.
        for (String key : all.keySet()) {
            String lk = key.toLowerCase();
            if (lk.endsWith('__loan_product__c')) {
                Integer dunder = lk.indexOf('__');
                if (dunder > 0) namespacePrefixes.add(lk.substring(0, dunder + 2));
            } else if (lk == 'loan_product__c') {
                // Unmanaged install — no prefix needed; record empty marker.
                namespacePrefixes.add('');
            }
        }
        // Always probe clcommon too — it's a separate dependency package.
        if (!namespacePrefixes.contains('clcommon__')) {
            for (String key : all.keySet()) {
                if (key.toLowerCase().startsWith('clcommon__')) {
                    namespacePrefixes.add('clcommon__');
                    break;
                }
            }
        }
        return namespacePrefixes;
    }

    @HttpGet
    global static void doGet() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String uri  = RestContext.request.requestURI;
        String tail = parseTail(uri);

        try {
            if (tail == 'products') {
                res.responseBody = Blob.valueOf(JSON.serialize(listProducts()));
                return;
            }
            if (tail.startsWith('product/')) {
                String productId = tail.substring('product/'.length());
                if (String.isBlank(productId)) {
                    writeError(res, 400, 'Missing product id');
                    return;
                }
                res.responseBody = Blob.valueOf(JSON.serialize(buildProductGraph(productId)));
                return;
            }
            if (tail.startsWith('debug/')) {
                String productId = tail.substring('debug/'.length());
                res.responseBody = Blob.valueOf(JSON.serialize(debugProduct(productId)));
                return;
            }
            if (tail.startsWith('diff/')) {
                // /diff/<ObjectName>/<RecordId>  → diffs source vs target by Id.
                String rest = tail.substring('diff/'.length());
                Integer slashIdx = rest.indexOf('/');
                if (slashIdx < 0) { writeError(res, 400, 'Use /diff/<Object>/<Id>'); return; }
                String objName = rest.substring(0, slashIdx);
                String recId   = rest.substring(slashIdx + 1);
                res.responseBody = Blob.valueOf(JSON.serialize(diffRecord(objName, recId)));
                return;
            }
            writeError(res, 404, 'Unknown route. Use /products or /product/<id>.');
        } catch (Exception e) {
            writeError(res, 500, e.getMessage());
        }
    }

    @HttpPost
    global static void doPost() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String tail = parseTail(RestContext.request.requestURI);

        try {
            if (tail == 'deploy') {
                String body = RestContext.request.requestBody == null
                    ? ''
                    : RestContext.request.requestBody.toString();
                if (String.isBlank(body)) {
                    writeError(res, 400, 'Empty request body');
                    return;
                }
                Map<String, Object> payload;
                try {
                    payload = (Map<String, Object>) JSON.deserializeUntyped(body);
                } catch (Exception je) {
                    writeError(res, 400,
                        'Invalid JSON body: ' +
                        (je.getMessage() == null ? je.getTypeName() : je.getMessage()));
                    return;
                }
                res.responseBody = Blob.valueOf(JSON.serialize(deployProduct(payload)));
                return;
            }
            writeError(res, 404, 'Unknown POST route. Use /deploy.');
        } catch (Exception e) {
            String msg = e.getMessage();
            if (String.isBlank(msg)) msg = e.getTypeName();
            // Surface the stack trace too — without it, some Apex exceptions
            // (NullPointerException, ClassCastException) are unidentifiable.
            try {
                msg += ' | at line ' + e.getLineNumber() + ' | ' + e.getStackTraceString();
            } catch (Exception ignored) {}
            writeError(res, 500, msg);
        }
    }

    /** Extracts the part of the URI after `/loanproductconfig/`. */
    private static String parseTail(String uri) {
        if (uri == null) return '';
        Integer idx = uri.indexOf('/loanproductconfig/');
        if (idx < 0) return '';
        String tail = uri.substring(idx + '/loanproductconfig/'.length());
        if (tail.endsWith('/')) tail = tail.substring(0, tail.length() - 1);
        return tail;
    }

    private static void writeError(RestResponse res, Integer status, String message) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(
            new Map<String, Object>{
                'success'      => false,
                'errorMessage' => message
            }
        ));
    }

    // ─── /debug/<id>: diagnostic dump ───────────────────────────────────────────

    /**
     * Returns the actual SOQL string, the resolved field list, the raw
     * getPopulatedFieldsAsMap() output, and the first ~50 keys from the
     * Loan_Product__c field describe map. Used to diagnose why custom fields
     * come back empty (FLS, namespace mismatch, blank record, etc.).
     */
    public static Map<String, Object> debugProduct(String productId) {
        Map<String, Object> out = new Map<String, Object>();
        out.put('requestedId', productId);

        // What the schema looks like from this Apex's perspective.
        // Use describeOnce so we don't break compilation in orgs where the
        // package namespace differs (Loan_Product__c → <ns>__Loan_Product__c).
        Schema.DescribeSObjectResult productDr = describeOnce('Loan_Product__c');
        Map<String, Schema.SObjectField> fieldMap = productDr == null
            ? new Map<String, Schema.SObjectField>()
            : productDr.fields.getMap();
        List<String> sampleKeys = new List<String>();
        Integer i = 0;
        for (String k : fieldMap.keySet()) {
            sampleKeys.add(k);
            if (++i >= 60) break;
        }
        out.put('totalFieldsOnObject', fieldMap.size());
        out.put('sampleFieldKeys', sampleKeys);

        // Resolved query field list (every accessible field, system fields stripped).
        List<String> resolved = getQueryableFields('Loan_Product__c');
        out.put('resolvedFieldsForQuery', resolved);

        // Build and run the SOQL exactly as buildProductGraph would.
        String soql;
        try {
            Id pid = (Id) productId;
            soql = 'SELECT ' + String.join(resolved, ', ') +
                   ' FROM ' + resolveObjectName('Loan_Product__c') + ' WHERE Id = :pid LIMIT 1';
            out.put('soql', soql);
            List<SObject> recs = Database.query(soql);
            if (recs.isEmpty()) {
                out.put('error', 'No record found for id');
                return out;
            }
            out.put('populatedFieldsAsMap', recs[0].getPopulatedFieldsAsMap());
        } catch (Exception e) {
            out.put('queryError', e.getMessage());
            out.put('soql', soql);
        }
        return out;
    }

    /**
     * /diff/<Object>/<RecordId> — diagnostic for the deploy equality check.
     * Reads the record by Id, builds the same `snapshotFields` shape the
     * deploy would send, then runs the equality check against itself
     * (and any other records sharing its Name) and returns *why* each
     * candidate didn't match.
     */
    public static Map<String, Object> diffRecord(String objName, String recId) {
        Map<String, Object> out = new Map<String, Object>();
        out.put('object', objName);
        out.put('recordId', recId);

        Schema.DescribeSObjectResult dr = describeOnce(objName);
        if (dr == null) { out.put('error', 'Unknown object'); return out; }

        List<String> fields = getQueryableFields(objName);
        Id pid;
        try { pid = (Id) recId; } catch (Exception e) { out.put('error', 'Invalid id'); return out; }

        SObject src;
        try {
            src = Database.query(
                'SELECT ' + String.join(fields, ', ') +
                ' FROM ' + resolveObjectName(objName) + ' WHERE Id = :pid LIMIT 1'
            )[0];
        } catch (Exception e) {
            out.put('error', 'Query failed: ' + e.getMessage());
            return out;
        }

        Map<String, Object> snapshotShape = sobjectToMap(src, fields);
        Map<String, Object> snapshotFields = (Map<String, Object>) snapshotShape.get('fields');
        out.put('sourceRecord', snapshotShape);

        String name = String.valueOf(snapshotShape.get('Name'));
        if (String.isBlank(name)) { out.put('error', 'No Name'); return out; }
        Set<String> nameSet = new Set<String>{ name };

        List<Map<String, Object>> candidates = new List<Map<String, Object>>();
        Map<String, String> idRemap = new Map<String, String>();
        try {
            for (SObject cand : Database.query(
                    'SELECT ' + String.join(fields, ', ') +
                    ' FROM ' + resolveObjectName(objName) + ' WHERE Name IN :nameSet')) {
                Map<String, Object> candDiff = new Map<String, Object>();
                candDiff.put('candidateId', String.valueOf(cand.get('Id')));
                List<Map<String, Object>> mismatches = new List<Map<String, Object>>();

                Map<String, Object> targetIdx = indexPopulated(cand.getPopulatedFieldsAsMap());

                // Loop 1: snapshot has, target differs.
                for (String f : snapshotFields.keySet()) {
                    if (f == 'Name' || f == 'Id') continue;
                    Object snapVal = snapshotFields.get(f);
                    Object tgtVal  = targetIdx.get(f.toLowerCase());
                    if (!valuesEqual(snapVal, tgtVal)) {
                        mismatches.add(new Map<String, Object>{
                            'field' => f,
                            'reason' => 'snapshot-vs-target differ',
                            'snapshot' => snapVal,
                            'target' => tgtVal
                        });
                    }
                }

                // Loop 2: target has populated, snapshot doesn't.
                Set<String> snapshotKeysCi = new Set<String>();
                for (String sk : snapshotFields.keySet()) snapshotKeysCi.add(sk.toLowerCase());
                for (String tk : targetIdx.keySet()) {
                    if (tk == 'id' || tk == 'name') continue;
                    if (SYSTEM_FIELD_SKIP.contains(tk)) continue;
                    String tkBare = tk;
                    Integer dunder = tk.indexOf('__');
                    if (dunder > 0 && tk.endsWith('__c') && tk.indexOf('__c') > dunder) {
                        tkBare = tk.substring(dunder + 2);
                    }
                    if (snapshotKeysCi.contains(tkBare) || snapshotKeysCi.contains(tk)) continue;
                    Object tv = targetIdx.get(tk);
                    if (isAbsent(tv)) continue;
                    if (tv instanceof Boolean && Boolean.valueOf(tv) == false) continue;
                    if (tv instanceof Decimal && Decimal.valueOf(String.valueOf(tv)) == 0) continue;
                    if (tv instanceof Integer && (Integer) tv == 0) continue;
                    mismatches.add(new Map<String, Object>{
                        'field' => tk,
                        'reason' => 'target-has-extra',
                        'snapshot' => null,
                        'target' => tv
                    });
                }

                candDiff.put('mismatches', mismatches);
                candDiff.put('matches', mismatches.isEmpty());
                candidates.add(candDiff);
            }
        } catch (Exception e) {
            out.put('error', 'Candidate query failed: ' + e.getMessage());
            return out;
        }

        out.put('candidates', candidates);
        return out;
    }

    // ─── /products: lightweight selection list ──────────────────────────────────

    public static Map<String, Object> listProducts() {
        List<Map<String, Object>> products = new List<Map<String, Object>>();
        String productObj  = resolveObjectName('Loan_Product__c');
        String typeField   = resolveFieldOnObject('Loan_Product__c', 'Loan_Product_Type__c');
        String statusField = resolveFieldOnObject('Loan_Product__c', 'Status__c');
        for (SObject rec : Database.query(
                'SELECT Id, Name, ' + typeField + ', ' + statusField +
                ' FROM ' + productObj + ' ORDER BY Name')) {
            Map<String, Object> idx = indexPopulated(rec.getPopulatedFieldsAsMap());
            Map<String, Object> row = new Map<String, Object>();
            Object id   = idx.get('id');
            Object nm   = idx.get('name');
            Object tp   = idx.get('loan_product_type__c');
            Object stat = idx.get('status__c');
            if (id   != null) row.put('Id', id);
            if (nm   != null) row.put('Name', nm);
            if (tp   != null) row.put('Loan_Product_Type__c', tp);
            if (stat != null) row.put('Status__c', stat);
            products.add(row);
        }

        return new Map<String, Object>{
            'success'      => true,
            'extractedAt'  => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'apiVersion'   => '60.0',
            'totalProducts' => products.size(),
            'orgId'        => UserInfo.getOrganizationId(),
            'orgName'      => UserInfo.getOrganizationName(),
            'loanProducts' => products
        };
    }

    // ─── /product/<id>: one product's full configuration graph ──────────────────

    public static Map<String, Object> buildProductGraph(String productId) {
        Id pid;
        try {
            pid = (Id) productId;
        } catch (Exception ignored) {
            return new Map<String, Object>{
                'success'      => false,
                'errorMessage' => 'Invalid product id: ' + productId
            };
        }

        // 1. Fetch the loan product with every accessible field (system fields stripped).
        List<String> productFields = getQueryableFields('Loan_Product__c');
        List<SObject> products = Database.query(
            'SELECT ' + String.join(productFields, ', ') +
            ' FROM ' + resolveObjectName('Loan_Product__c') + ' WHERE Id = :pid LIMIT 1'
        );
        if (products.isEmpty()) {
            return new Map<String, Object>{
                'success'      => false,
                'errorMessage' => 'Loan product not found: ' + productId
            };
        }

        Map<String, Object> loanProduct = sobjectToMap(products[0], productFields);
        Map<String, Object> rawFields = (Map<String, Object>) loanProduct.get('fields');

        // 2. Collect referenced IDs from the product's lookup fields.
        Set<Id> feeSetIds        = collectIds(rawFields, new List<String>{ 'Fee_Set__c' });
        Set<Id> delinquencyIds   = collectIds(rawFields, new List<String>{ 'Delinquency_Aging_Set__c', 'Loss_Provisioning_Set__c' });
        Set<Id> floatingIds      = collectIds(rawFields, new List<String>{ 'Floating_Rate_Index__c' });
        Set<Id> referenceIds     = collectIds(rawFields, new List<String>{ 'Reference_Rate_Index__c' });
        Set<Id> loanParamIds     = collectIds(rawFields, new List<String>{ 'Loan_Parameters__c' });
        Set<Id> promotionIds     = collectIds(rawFields, new List<String>{ 'Promotions__c' });
        Set<Id> holidayIds       = collectIds(rawFields, new List<String>{ 'Holiday_Treatment_Setup__c' });
        Set<Id> clawbackIds      = collectIds(rawFields, new List<String>{ 'Clawback_Rule_Set__c' });

        // 3. Fetch each referenced related-object record.
        Map<String, List<Map<String, Object>>> related = new Map<String, List<Map<String, Object>>>();

        FeeSetFetch feeSetFetch = fetchFeeSets(feeSetIds);
        related.put('Fee_Set__c',                           feeSetFetch.records);
        related.put('Delinquency_Set__c',                   fetchDelinquencySets(delinquencyIds));
        related.put('Floating_Rate_Index__c',               fetchParentWithChildren('Floating_Rate_Index__c', 'Floating_Rate__c', 'Floating_Rate_Index__c', floatingIds));
        related.put('Reference_Rate_Index__c',              queryByIds('Reference_Rate_Index__c',              referenceIds));
        related.put('Loan_Parameters__c',                   queryByIds('Loan_Parameters__c',                   loanParamIds));
        related.put('clcommon__Promotions__c',              queryByIds('clcommon__Promotions__c',              promotionIds));
        related.put('clcommon__Holiday_Treatment_Setup__c', queryByIds('clcommon__Holiday_Treatment_Setup__c', holidayIds));
        related.put('clcommon__Rule_Set__c',                queryByIds('clcommon__Rule_Set__c',                clawbackIds));

        // 4. Dynamically fetch every custom child relationship of Loan_Product__c
        //    keyed by the lookup field that points back to this product.
        Map<String, List<Map<String, Object>>> children = fetchProductChildren(pid);

        // 5. Resolve Fee__c records referenced by Fee_Junction__c children.
        Map<String, Map<String, Object>> fees = resolveFees(feeSetFetch.feeIds);

        // 6. Resolve secondary lookups so the portal can show Names instead of
        //    raw Ids: GL accounts on the loan product, and curated lookup fields
        //    on each child relationship row (Business Event, Accounting Rule
        //    Header, Delinquency Interval, Commission Plan).
        resolveExtraReferences(rawFields, children, related);

        return new Map<String, Object>{
            'success'        => true,
            'extractedAt'    => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'apiVersion'     => '60.0',
            'loanProduct'    => loanProduct,
            'relatedObjects' => related,
            'children'       => children,
            'fees'           => fees,
            'orgId'          => UserInfo.getOrganizationId(),
            'orgName'        => UserInfo.getOrganizationName()
        };
    }

    // ─── Schema / field utilities ───────────────────────────────────────────────

    private static Schema.DescribeSObjectResult describeOnce(String objectName) {
        if (describeCache.containsKey(objectName)) return describeCache.get(objectName);
        Schema.DescribeSObjectResult dr;
        try {
            dr = Schema.describeSObjects(new List<String>{ objectName })[0];
        } catch (Exception e) {
            // Fallback: maybe the object lives under a package namespace
            // (this Apex class is deployed unmanaged into a package-installed
            // org, so bare names don't resolve in dynamic SOQL/describe).
            // Try each detected namespace prefix until something sticks.
            for (String ns : getNamespacePrefixes()) {
                if (String.isBlank(ns)) continue;
                try {
                    dr = Schema.describeSObjects(new List<String>{ ns + objectName })[0];
                    break;
                } catch (Exception ignored) {}
            }
        }
        describeCache.put(objectName, dr);
        return dr;
    }

    /**
     * Returns the canonical SObject API name for SOQL/describe usage. When the
     * Apex class is deployed unmanaged into an org where the package landed at
     * a namespace (e.g. `loan__`), bare names like `Loan_Product__c` are not
     * resolvable; this prepends the right prefix. Bare name is returned when
     * the type already exists unprefixed (Apex inside the package, or unmanaged
     * package install).
     */
    private static Map<String, String> resolvedNameCache = new Map<String, String>();
    private static String resolveObjectName(String bareOrPrefixed) {
        if (resolvedNameCache.containsKey(bareOrPrefixed)) {
            return resolvedNameCache.get(bareOrPrefixed);
        }
        Schema.SObjectType t = resolveSObjectType(bareOrPrefixed);
        String canonical = t == null
            ? bareOrPrefixed
            : t.getDescribe().getName();
        resolvedNameCache.put(bareOrPrefixed, canonical);
        return canonical;
    }

    /**
     * Standard system fields stripped from every output record. They add heap
     * weight, leak per-org user identifiers, and never affect product behaviour.
     * Lowercased for case-insensitive matching in the filter loop.
     */
    private static final Set<String> SYSTEM_FIELD_SKIP = new Set<String>{
        'createddate', 'createdbyid',
        'lastmodifieddate', 'lastmodifiedbyid',
        'systemmodstamp',
        'isdeleted', 'ownerid',
        'recordtypeid',
        'lastvieweddate', 'lastreferenceddate',
        'lastactivitydate'
    };

    /**
     * Returns accessible field API names for the object, **without** namespace
     * prefix. This Apex class is deployed inside the `w22loan` managed package
     * so SOQL accepts bare names; emitting bare names everywhere keeps the
     * snapshot output consistent and aligned with our static label dictionary.
     * System / audit fields (CreatedDate, LastModifiedDate, etc.) are skipped.
     */
    private static List<String> getQueryableFields(String objectName) {
        if (fieldsCache.containsKey(objectName)) return fieldsCache.get(objectName);
        Schema.DescribeSObjectResult dr = describeOnce(objectName);
        List<String> out = new List<String>();
        if (dr != null) {
            for (Schema.SObjectField f : dr.fields.getMap().values()) {
                Schema.DescribeFieldResult fr = f.getDescribe();
                if (!fr.isAccessible()) continue;
                String name = fr.getName();
                Integer dunder = name.indexOf('__');
                String bare = name;
                if (dunder > 0 && name.endsWith('__c') && name.indexOf('__c') > dunder) {
                    bare = name.substring(dunder + 2);
                }
                if (SYSTEM_FIELD_SKIP.contains(bare.toLowerCase())) continue;
                // Return the **canonical** (possibly namespace-prefixed) name so
                // dynamic SOQL works regardless of where this Apex is deployed
                // — inside the managed package (bare names resolve) or as
                // unmanaged code in a package-installed org (must be prefixed).
                out.add(name);
            }
        }
        if (out.isEmpty()) out = new List<String>{ 'Id', 'Name' };
        fieldsCache.put(objectName, out);
        return out;
    }

    /** Strips a namespace prefix to a bare api name: `loan__Foo__c` → `Foo__c`. */
    private static String bareFieldName(String name) {
        if (name == null) return name;
        Integer dunder = name.indexOf('__');
        if (dunder > 0 && name.endsWith('__c') && name.indexOf('__c') > dunder) {
            return name.substring(dunder + 2);
        }
        return name;
    }

    /**
     * Returns the canonical (possibly namespace-prefixed) name of `bareField` on
     * `objectName`. Used for hand-built SOQL field lists. Falls back to the
     * bare name when describe is unavailable so callers still get a usable
     * (if possibly invalid) value rather than null in the SOQL string.
     */
    private static String resolveFieldOnObject(String objectName, String bareField) {
        Schema.DescribeSObjectResult dr = describeOnce(objectName);
        if (dr == null) return bareField;
        Map<String, Schema.SObjectField> fmap = dr.fields.getMap();
        // Standard fields like Id / Name / OwnerId have no prefix and are
        // keyed lower-case in the describe map.
        String lower = bareField.toLowerCase();
        if (fmap.containsKey(lower)) {
            return fmap.get(lower).getDescribe().getName();
        }
        for (String ns : getNamespacePrefixes()) {
            if (String.isBlank(ns)) continue;
            String key = (ns + bareField).toLowerCase();
            if (fmap.containsKey(key)) {
                return fmap.get(key).getDescribe().getName();
            }
        }
        return bareField;
    }

    /** Pulls a list of Id values out of a reshaped fields map. */
    private static Set<Id> collectIds(Map<String, Object> fields, List<String> apiNames) {
        Set<Id> ids = new Set<Id>();
        if (fields == null) return ids;
        for (String name : apiNames) {
            Object val = fields.get(name);
            if (val == null) continue;
            try {
                ids.add((Id) val);
            } catch (Exception ignored) {}
        }
        return ids;
    }

    // ─── SObject → Map (raw values; labels resolved client-side) ────────────────

    /**
     * `getPopulatedFieldsAsMap()` returns keys with whatever casing/namespace
     * the runtime emits — for managed-package fields accessed from a session
     * outside the package context the keys come back as `w22loan__foo__c`.
     * This builds a lowercase index that handles both bare and prefixed keys
     * so we can look up by bare api name and always emit the bare name in the
     * output (consistent snapshot regardless of org namespace state).
     */
    private static Map<String, Object> indexPopulated(Map<String, Object> populated) {
        Map<String, Object> idx = new Map<String, Object>();
        for (String k : populated.keySet()) {
            String lk = k.toLowerCase();
            idx.put(lk, populated.get(k));
            Integer dunder = lk.indexOf('__');
            if (dunder > 0 && lk.endsWith('__c') && lk.indexOf('__c') > dunder) {
                idx.put(lk.substring(dunder + 2), populated.get(k));
            }
        }
        return idx;
    }

    private static Map<String, Object> sobjectToMap(SObject record, List<String> fields) {
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        Map<String, Object> idx       = indexPopulated(populated);
        Map<String, Object> result    = new Map<String, Object>();
        Map<String, Object> fieldsOut = new Map<String, Object>();

        Object idVal = idx.get('id');
        if (idVal != null) result.put('Id', idVal);

        Object nameVal = idx.get('name');
        if (nameVal != null && !(nameVal instanceof String && ((String) nameVal).trim() == '')) {
            result.put('Name', nameVal);
        }

        for (String f : fields) {
            if (f == 'Id' || f == 'Name') continue;
            Object val = idx.get(f.toLowerCase());
            if (val == null) continue;
            if (val instanceof String && ((String) val).trim() == '') continue;
            // Emit bare api name so client-side label dictionaries (which
            // are namespace-agnostic) can resolve labels consistently
            // regardless of which org the snapshot was extracted from.
            fieldsOut.put(bareFieldName(f), val);
        }
        result.put('fields', fieldsOut);
        return result;
    }

    /**
     * Children of Loan_Product__c that are per-loan-instance, transactional, or
     * historical — NOT product configuration. Capturing them would leak borrower
     * data into Golden Copy snapshots and bloat the payload with rows that
     * don't belong in a config library. Match is by bare api name (lowercased).
     */
    private static final Set<String> CHILD_DENYLIST = new Set<String>{
        // Per-loan instance + history
        'loan_account__c',
        'loan_account_history__c',
        'loan_account_due_details__c',
        'loan_account_conditions__c',
        'loan_account_interface__c',
        'loan_status_history__c',
        'investor_loan__c',
        'branch_loan_product__c',
        // Junctions / handled elsewhere
        'fee_junction__c'
    };

    /**
     * Dynamically fetches every custom child of Loan_Product__c — one query per
     * child relationship. Returns a map keyed by child object API name (bare).
     * Skips Fee_Junction__c (handled inside fetchFeeSets), per-instance / history
     * objects (CHILD_DENYLIST), and anything ending in transactional / interface
     * naming patterns so borrower data never lands in a config snapshot.
     */
    private static Map<String, List<Map<String, Object>>> fetchProductChildren(Id pid) {
        Map<String, List<Map<String, Object>>> out = new Map<String, List<Map<String, Object>>>();
        Schema.DescribeSObjectResult dr = describeOnce('Loan_Product__c');
        if (dr == null) return out;

        for (Schema.ChildRelationship rel : dr.getChildRelationships()) {
            String childObj = String.valueOf(rel.getChildSObject());
            if (childObj == null || !childObj.endsWith('__c')) continue;
            String bareChild = stripNs(childObj);
            String lower     = bareChild.toLowerCase();

            // Explicit denylist of per-instance + junction objects.
            if (CHILD_DENYLIST.contains(lower)) continue;

            // Defensive name-based filter for transactional / interface / snapshot tables.
            if (lower.endsWith('_transaction__c') ||
                lower.endsWith('_interface__c') ||
                lower.endsWith('_history__c') ||
                lower.endsWith('_snapshot__c')) {
                continue;
            }

            Schema.SObjectField lookupField = rel.getField();
            if (lookupField == null) continue;
            // Use the canonical (prefixed when applicable) field name in SOQL.
            String lookupName = lookupField.getDescribe().getName();

            List<String> fields = getQueryableFields(childObj);
            if (fields.isEmpty()) continue;

            try {
                List<Map<String, Object>> rows = new List<Map<String, Object>>();
                for (SObject rec : Database.query(
                        'SELECT ' + String.join(fields, ', ') +
                        ' FROM ' + childObj +
                        ' WHERE ' + lookupName + ' = :pid')) {
                    rows.add(sobjectToMap(rec, fields));
                }
                if (!rows.isEmpty()) {
                    // Use bare child name in the snapshot key for label-dictionary alignment.
                    out.put(bareChild, rows);
                }
            } catch (Exception ignored) {}
        }
        return out;
    }

    /** Strips a leading namespace prefix from an api name (`w22loan__Foo__c` → `Foo__c`). */
    private static String stripNs(String name) {
        if (name == null) return name;
        Integer dunder = name.indexOf('__');
        if (dunder > 0 && name.endsWith('__c') && name.indexOf('__c') > dunder) {
            return name.substring(dunder + 2);
        }
        return name;
    }

    /** Bulk-queries an object by Id set; returns reshaped records. Empty set → no SOQL. */
    private static List<Map<String, Object>> queryByIds(String objectName, Set<Id> ids) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (ids == null || ids.isEmpty()) return out;
        if (describeOnce(objectName) == null) return out;

        List<String> fields = getQueryableFields(objectName);
        if (fields.isEmpty()) return out;

        try {
            String soql = 'SELECT ' + String.join(fields, ', ') +
                          ' FROM ' + resolveObjectName(objectName) + ' WHERE Id IN :ids';
            for (SObject rec : Database.query(soql)) {
                out.add(sobjectToMap(rec, fields));
            }
        } catch (Exception ignored) {}
        return out;
    }

    // ─── Fee_Set__c (with Fee_Junction__c children) and Fee__c resolution ───────

    private class FeeSetFetch {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        Set<Id>                   feeIds  = new Set<Id>();
    }

    /**
     * Fetches Fee_Set__c records by Id with their Fee_Junction__c children.
     * Junction children are returned with a `feeId` shortcut so the portal can
     * navigate `junction.feeId → fees[id]`. Collected fee IDs are returned for
     * the second-pass Fee__c resolution.
     */
    private static FeeSetFetch fetchFeeSets(Set<Id> feeSetIds) {
        FeeSetFetch out = new FeeSetFetch();
        if (feeSetIds == null || feeSetIds.isEmpty()) return out;
        if (describeOnce('Fee_Set__c') == null) return out;

        List<String> feeSetFields  = getQueryableFields('Fee_Set__c');
        List<String> junctionFields = new List<String>{
            'Id',
            resolveFieldOnObject('Fee_Junction__c', 'Fee__c'),
            resolveFieldOnObject('Fee_Junction__c', 'Fee_Set__c')
        };

        // Fee sets in one query.
        Map<Id, Map<String, Object>> feeSetById = new Map<Id, Map<String, Object>>();
        try {
            for (SObject rec : Database.query(
                    'SELECT ' + String.join(feeSetFields, ', ') +
                    ' FROM ' + resolveObjectName('Fee_Set__c') + ' WHERE Id IN :feeSetIds')) {
                Map<String, Object> reshaped = sobjectToMap(rec, feeSetFields);
                feeSetById.put((Id) rec.get('Id'), reshaped);
            }
        } catch (Exception ignored) {
            return out;
        }

        // Junctions in a second query, grouped client-side.
        if (describeOnce('Fee_Junction__c') != null) {
            String feeJunctionObj  = resolveObjectName('Fee_Junction__c');
            String feeSetFieldOnJ  = resolveFieldOnObject('Fee_Junction__c', 'Fee_Set__c');
            try {
                for (SObject j : Database.query(
                        'SELECT ' + String.join(junctionFields, ', ') +
                        ' FROM ' + feeJunctionObj + ' WHERE ' + feeSetFieldOnJ + ' IN :feeSetIds')) {
                    Map<String, Object> jMap = sobjectToMap(j, junctionFields);
                    Map<String, Object> jFields = (Map<String, Object>) jMap.get('fields');
                    if (jFields == null) continue;
                    Object feeRef    = jFields.get('Fee__c');
                    Object feeSetRef = jFields.get('Fee_Set__c');
                    if (feeRef != null) {
                        jMap.put('feeId', String.valueOf(feeRef));
                        out.feeIds.add((Id) feeRef);
                    }
                    if (feeSetRef != null) {
                        Map<String, Object> parent = feeSetById.get((Id) feeSetRef);
                        if (parent != null) {
                            List<Map<String, Object>> bucket =
                                (List<Map<String, Object>>) parent.get('Fee_Junction__c');
                            if (bucket == null) {
                                bucket = new List<Map<String, Object>>();
                                parent.put('Fee_Junction__c', bucket);
                            }
                            bucket.add(jMap);
                        }
                    }
                }
            } catch (Exception ignored) {}
        }

        out.records = feeSetById.values();
        return out;
    }

    /**
     * Fetches Delinquency_Set__c records by Id along with their
     * Delinquency_Set_Junction__c children (linked to Delinquency_Interval__c).
     * Same pattern as fetchFeeSets — needed so the deploy-side equality check
     * has the junction children to compare against the target.
     */
    private static List<Map<String, Object>> fetchDelinquencySets(Set<Id> delinquencyIds) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (delinquencyIds == null || delinquencyIds.isEmpty()) return out;
        if (describeOnce('Delinquency_Set__c') == null) return out;

        List<String> setFields = getQueryableFields('Delinquency_Set__c');
        List<String> junctionFields = new List<String>{
            'Id',
            resolveFieldOnObject('Delinquency_Set_Junction__c', 'Delinquency_Interval__c'),
            resolveFieldOnObject('Delinquency_Set_Junction__c', 'Delinquency_Set__c')
        };

        Map<Id, Map<String, Object>> setById = new Map<Id, Map<String, Object>>();
        try {
            for (SObject rec : Database.query(
                    'SELECT ' + String.join(setFields, ', ') +
                    ' FROM ' + resolveObjectName('Delinquency_Set__c') + ' WHERE Id IN :delinquencyIds')) {
                Map<String, Object> reshaped = sobjectToMap(rec, setFields);
                setById.put((Id) rec.get('Id'), reshaped);
            }
        } catch (Exception ignored) {
            return out;
        }

        if (describeOnce('Delinquency_Set_Junction__c') != null) {
            String junctionObj = resolveObjectName('Delinquency_Set_Junction__c');
            String setFieldOnJ = resolveFieldOnObject('Delinquency_Set_Junction__c', 'Delinquency_Set__c');
            try {
                for (SObject j : Database.query(
                        'SELECT ' + String.join(junctionFields, ', ') +
                        ' FROM ' + junctionObj +
                        ' WHERE ' + setFieldOnJ + ' IN :delinquencyIds')) {
                    Map<String, Object> jMap = sobjectToMap(j, junctionFields);
                    Map<String, Object> jFields = (Map<String, Object>) jMap.get('fields');
                    if (jFields == null) continue;
                    Object setRef = jFields.get('Delinquency_Set__c');
                    if (setRef == null) continue;
                    Map<String, Object> parent = setById.get((Id) setRef);
                    if (parent == null) continue;
                    List<Map<String, Object>> bucket =
                        (List<Map<String, Object>>) parent.get('Delinquency_Set_Junction__c');
                    if (bucket == null) {
                        bucket = new List<Map<String, Object>>();
                        parent.put('Delinquency_Set_Junction__c', bucket);
                    }
                    bucket.add(jMap);
                }
            } catch (Exception ignored) {}
        }

        out.addAll(setById.values());
        return out;
    }

    /**
     * Generic deep-fetch: queries a parent object plus its direct custom children
     * in a second pass and nests them under the parent record using `childObjKey`
     * as the key. Used for any related object whose children must be included in
     * the snapshot so the deploy-side equality check can compare them.
     *
     * Example: fetchParentWithChildren('Floating_Rate_Index__c', 'Floating_Rate__c',
     *          'Floating_Rate_Index__c', ids) → each Floating_Rate_Index record
     *          carries { ..., 'Floating_Rate__c': [child rows] }.
     */
    private static List<Map<String, Object>> fetchParentWithChildren(
            String parentObj,
            String childObj,
            String childParentField,
            Set<Id> parentIds) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (parentIds == null || parentIds.isEmpty()) return out;
        if (describeOnce(parentObj) == null) return out;

        List<String> parentFields = getQueryableFields(parentObj);
        Map<Id, Map<String, Object>> parentById = new Map<Id, Map<String, Object>>();
        try {
            for (SObject rec : Database.query(
                    'SELECT ' + String.join(parentFields, ', ') +
                    ' FROM ' + resolveObjectName(parentObj) + ' WHERE Id IN :parentIds')) {
                Map<String, Object> reshaped = sobjectToMap(rec, parentFields);
                parentById.put((Id) rec.get('Id'), reshaped);
            }
        } catch (Exception ignored) {
            return out;
        }

        if (describeOnce(childObj) != null) {
            List<String> childFields = getQueryableFields(childObj);
            String childParentFieldResolved = resolveFieldOnObject(childObj, childParentField);
            try {
                for (SObject c : Database.query(
                        'SELECT ' + String.join(childFields, ', ') +
                        ' FROM ' + resolveObjectName(childObj) +
                        ' WHERE ' + childParentFieldResolved + ' IN :parentIds')) {
                    Map<String, Object> cMap = sobjectToMap(c, childFields);
                    Map<String, Object> cFields = (Map<String, Object>) cMap.get('fields');
                    if (cFields == null) continue;
                    // Find parent using the indexed populated map (namespace-tolerant).
                    Map<String, Object> idx = indexPopulated(c.getPopulatedFieldsAsMap());
                    Object parentRef = idx.get(childParentField.toLowerCase());
                    if (parentRef == null) continue;
                    Map<String, Object> parent = parentById.get((Id) parentRef);
                    if (parent == null) continue;
                    List<Map<String, Object>> bucket =
                        (List<Map<String, Object>>) parent.get(childObj);
                    if (bucket == null) {
                        bucket = new List<Map<String, Object>>();
                        parent.put(childObj, bucket);
                    }
                    bucket.add(cMap);
                }
            } catch (Exception ignored) {}
        }

        out.addAll(parentById.values());
        return out;
    }

    /** Bulk-queries Fee__c for the supplied Ids and returns an Id-keyed reshaped map. */
    private static Map<String, Map<String, Object>> resolveFees(Set<Id> feeIds) {
        Map<String, Map<String, Object>> out = new Map<String, Map<String, Object>>();
        if (feeIds == null || feeIds.isEmpty()) return out;
        if (describeOnce('Fee__c') == null) return out;

        List<String> fields = getQueryableFields('Fee__c');
        if (fields.isEmpty()) return out;

        try {
            String soql = 'SELECT ' + String.join(fields, ', ') +
                          ' FROM ' + resolveObjectName('Fee__c') + ' WHERE Id IN :feeIds';
            for (SObject rec : Database.query(soql)) {
                Map<String, Object> reshaped = sobjectToMap(rec, fields);
                Object idVal = reshaped.get('Id');
                if (idVal != null) out.put(String.valueOf(idVal), reshaped);
            }
        } catch (Exception ignored) {}
        return out;
    }

    // ─── Secondary reference resolution (GL accounts + curated child lookups) ──

    /**
     * Lookup field paths we resolve on each child relationship row. Map shape:
     *   childObjectBareName.lookupFieldBareName → targetObjectName for SOQL.
     * Anything not in this map is left as a raw Id in the output. This keeps
     * heap predictable while ensuring the portal can show meaningful names for
     * the references operators actually care about.
     */
    private static final Map<String, Map<String, String>> CHILD_LOOKUP_TARGETS =
        new Map<String, Map<String, String>>{
            'Loan_Product_Accounting_Setup__c' => new Map<String, String>{
                'Business_Event__c'    => 'Business_Event__c',
                'Default_Rule__c'      => 'Accounting_Rule_Header__c',
                'User_Defined_Rule__c' => 'Accounting_Rule_Header__c'
            },
            'Loan_Loss_Provisioning_Setup__c' => new Map<String, String>{
                'New_Class__c' => 'Delinquency_Interval__c'
            },
            'Default_Commission_Hierarchy__c' => new Map<String, String>{
                'Default_Commission_Plan__c' => 'Commission_Plan__c'
            }
        };

    /**
     * Lookup fields on related-object records (other than child relationship
     * rows) whose values are source-org Ids and must be remapped through
     * idRemap on deploy. Without this, an MF_Account__c.Account_Type__c set
     * to a source-org `MF_Account_Type__c` Id would be inserted verbatim and
     * the target rejects it with FIELD_INTEGRITY_EXCEPTION.
     *
     * Self-referential lookups (e.g. MF_Account__c.Parent_Account__c) work
     * here because the parent record is always inserted first within the
     * same processReferenceRecords call: its source→target Id is in idRemap
     * by the time we build SObjects for children that point at it.
     */
    private static final Map<String, Set<String>> RELATED_LOOKUP_FIELDS =
        new Map<String, Set<String>>{
            'MF_Account__c' => new Set<String>{ 'Account_Type__c', 'Parent_Account__c' },
            'Accounting_Rule_Header__c' => new Set<String>{ 'Business_Event__c' },
            'Loan_Parameters__c' => new Set<String>{ 'Clawback_Rule_Set__c' },
            'Fee__c' => new Set<String>{
                'Fee_Expense_Account__c', 'Fee_Prepay_Account__c',
                'Fee_Unearned_Income_Account__c', 'Income_Account__c',
                'Suspended_Fee_Account__c'
            },
            'Fee_Set__c' => new Set<String>{ 'Income_Account__c' },
            // Floating_Rate__c.Floating_Rate_Index__c is master-detail; the
            // parent must be inserted first (handled by ordering in
            // REFERENCE_OBJECTS_BY_NAME — Floating_Rate_Index__c comes
            // before Floating_Rate__c).
            'Floating_Rate__c' => new Set<String>{ 'Floating_Rate_Index__c' }
        };

    /**
     * Loan_Product__c lookup fields whose targets are second-tier reference
     * objects we need to pull into the snapshot so deploy can match-or-create
     * them. Map of source-bare lookup field on MF_Account__c → target object.
     */
    private static final Map<String, String> MF_ACCOUNT_LOOKUP_TARGETS =
        new Map<String, String>{
            'Account_Type__c' => 'MF_Account_Type__c'
        };

    /**
     * Loan_Product__c fields whose values are MF_Account__c Ids. Pulling the
     * referenced accounts means the portal can render "Loan Asset Account →
     * 1100 Loans Receivable" instead of just an Id.
     */
    private static final Set<String> GL_ACCOUNT_FIELDS = new Set<String>{
        'Product_Asset_Account__c',
        'Product_Interest_Income_Account__c',
        'Product_Interest_Expense_Account__c',
        'Product_Loan_Control_Account__c',
        'Product_Overdue_Interest_Account__c',
        'Product_Suspended_Interest_Account__c',
        'Product_Fee_Expense_Account__c',
        'Product_Service_Fee_Income_Account__c',
        'Product_Write_Off_Recovery_Account__c',
        'Product_Loan_Loss_Provision_Account__c',
        'Product_Loan_Loss_Reserve_Account__c',
        'Product_Excess_Account__c',
        'Product_Interest_Amortization_Account__c',
        'Product_Int_On_Overdue_Income_Acc__c',
        'Product_Suspended_Int_On_Overdue_Acc__c',
        'Product_Loan_Purchase_Payable_Account__c',
        'Product_Loan_Purchase_Receivable_Account__c'
    };

    /**
     * Mutates `relatedObjects` in place to add bulk-fetched secondary records
     * (GL accounts, business events, accounting rule headers, delinquency
     * intervals, commission plans) so the portal can resolve Id → Name.
     */
    private static void resolveExtraReferences(
            Map<String, Object> productFields,
            Map<String, List<Map<String, Object>>> children,
            Map<String, List<Map<String, Object>>> relatedObjects) {

        Map<String, Set<Id>> idsByTarget = new Map<String, Set<Id>>();

        // (a) GL accounts on the loan product itself.
        if (productFields != null) {
            Set<Id> glIds = new Set<Id>();
            for (String f : GL_ACCOUNT_FIELDS) {
                Object v = productFields.get(f);
                if (v == null) continue;
                try { glIds.add((Id) v); } catch (Exception ignored) {}
            }
            if (!glIds.isEmpty()) idsByTarget.put('MF_Account__c', glIds);
        }

        // (b) Curated lookups on each child relationship row.
        if (children != null) {
            for (String childName : children.keySet()) {
                Map<String, String> lookupMap = CHILD_LOOKUP_TARGETS.get(childName);
                if (lookupMap == null) continue;
                List<Map<String, Object>> rows = children.get(childName);
                if (rows == null || rows.isEmpty()) continue;

                for (Map<String, Object> row : rows) {
                    Map<String, Object> rowFields = (Map<String, Object>) row.get('fields');
                    if (rowFields == null) continue;
                    for (String lookupField : lookupMap.keySet()) {
                        Object v = rowFields.get(lookupField);
                        if (v == null) continue;
                        String target = lookupMap.get(lookupField);
                        Set<Id> bucket = idsByTarget.get(target);
                        if (bucket == null) {
                            bucket = new Set<Id>();
                            idsByTarget.put(target, bucket);
                        }
                        try { bucket.add((Id) v); } catch (Exception ignored) {}
                    }
                }
            }
        }

        // (c) Bulk-fetch each target object and attach to relatedObjects.
        for (String target : idsByTarget.keySet()) {
            mergeFetchedRecords(relatedObjects, target, idsByTarget.get(target));
        }

        // (d) Second pass: now that MF_Account__c records are loaded (either
        //     fetched in (c) or already present), pull every distinct
        //     `Account_Type__c` Id across them and resolve those records too.
        //     Without this the deploy carries a source-org Id in
        //     MF_Account__c.Account_Type__c that the target rejects with
        //     FIELD_INTEGRITY_EXCEPTION.
        List<Map<String, Object>> mfAccounts = relatedObjects.get('MF_Account__c');
        if (mfAccounts != null && !mfAccounts.isEmpty()) {
            for (String lookupField : MF_ACCOUNT_LOOKUP_TARGETS.keySet()) {
                String targetObj = MF_ACCOUNT_LOOKUP_TARGETS.get(lookupField);
                Set<Id> ids = new Set<Id>();
                for (Map<String, Object> row : mfAccounts) {
                    Map<String, Object> f = (Map<String, Object>) row.get('fields');
                    if (f == null) continue;
                    Object v = f.get(lookupField);
                    if (v == null) continue;
                    try { ids.add((Id) v); } catch (Exception ignored) {}
                }
                mergeFetchedRecords(relatedObjects, targetObj, ids);
            }
        }
    }

    /**
     * Bulk-fetches `target` records by Id and merges them into
     * `relatedObjects[target]`, skipping any Ids already present.
     */
    private static void mergeFetchedRecords(
            Map<String, List<Map<String, Object>>> relatedObjects,
            String target,
            Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return;
        Set<Id> existing = new Set<Id>();
        List<Map<String, Object>> already = relatedObjects.get(target);
        if (already != null) {
            for (Map<String, Object> r : already) {
                Object idVal = r.get('Id');
                if (idVal != null) {
                    try { existing.add((Id) idVal); } catch (Exception ignored) {}
                }
            }
        }
        Set<Id> needed = new Set<Id>(ids);
        needed.removeAll(existing);
        if (needed.isEmpty()) return;

        List<Map<String, Object>> fetched = queryByIds(target, needed);
        if (fetched.isEmpty()) return;
        if (already == null) {
            relatedObjects.put(target, fetched);
        } else {
            already.addAll(fetched);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Deploy ───────────────────────────────────────────────────────────────────
    //
    // POST /v1/loanproductconfig/deploy
    //
    // Accepts an edited Golden Copy product graph and creates the records in
    // the connected (target) org. Reference records (Fee_Set, Delinquency_Set,
    // GL accounts, etc.) are looked up by Name first — reused if found,
    // inserted if not. Child relationship rows (Loan_Product_Accounting_Setup,
    // Loan_Loss_Provisioning_Setup, etc.) are always inserted because they
    // belong to this specific product.
    //
    // The whole operation runs inside a savepoint; any failure rolls back.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Reference object types that support match-by-Name. Order matters —
     * dependencies first. Fee__c is created before Fee_Set__c so junctions
     * have valid Ids; Fee_Set__c before Fee_Junction__c rows that link them;
     * everything else before Loan_Product__c which references them all.
     */
    private static final List<String> REFERENCE_OBJECTS_BY_NAME = new List<String>{
        // MF_Account_Type__c must come before MF_Account__c so its source→target
        // Id is in idRemap by the time MF_Account__c.Account_Type__c is built.
        'MF_Account_Type__c',
        'MF_Account__c',
        'Business_Event__c',
        'Accounting_Rule_Header__c',
        'Delinquency_Interval__c',
        'Commission_Plan__c',
        // Floating_Rate_Index__c (parent) processed first so its target Id
        // is in idRemap before Floating_Rate__c children try to set their
        // master-detail field. Children whose parent was REUSED are skipped
        // at processing time (the reused parent already carries its own
        // children, and content equality already proved they match).
        'Floating_Rate_Index__c',
        'Floating_Rate__c',
        'Reference_Rate_Index__c',
        'clcommon__Holiday_Treatment_Setup__c',
        'clcommon__Rule_Set__c',
        'clcommon__Promotions__c',
        'Delinquency_Set__c',
        'Loan_Parameters__c',
        'Fee__c',
        'Fee_Set__c'
    };

    /** All lookup fields on Loan_Product__c whose Ids must be remapped on deploy. */
    private static final Set<String> PRODUCT_LOOKUP_FIELDS = new Set<String>{
        'Fee_Set__c',
        'Delinquency_Aging_Set__c', 'Loss_Provisioning_Set__c',
        'Floating_Rate_Index__c', 'Reference_Rate_Index__c',
        'Loan_Parameters__c', 'Funder__c', 'Business_Hours__c',
        'Holiday_Treatment_Setup__c', 'Savings_Product__c', 'Promotions__c',
        'Parent_Loan_Product__c', 'Clawback_Rule_Set__c',
        // GL accounts → MF_Account__c
        'Product_Asset_Account__c', 'Product_Interest_Income_Account__c',
        'Product_Interest_Expense_Account__c', 'Product_GL_Code_Principal__c',
        'Product_GL_Code_Interest__c', 'Product_Loan_Control_Account__c',
        'Product_Overdue_Interest_Account__c', 'Product_Suspended_Interest_Account__c',
        'Product_Fee_Expense_Account__c', 'Product_Service_Fee_Income_Account__c',
        'Product_Write_Off_Recovery_Account__c', 'Product_Loan_Loss_Provision_Account__c',
        'Product_Loan_Loss_Reserve_Account__c', 'Product_Excess_Account__c',
        'Product_Interest_Amortization_Account__c',
        'Product_Int_On_Overdue_Income_Acc__c', 'Product_Suspended_Int_On_Overdue_Acc__c',
        'Product_Loan_Purchase_Payable_Account__c', 'Product_Loan_Purchase_Receivable_Account__c'
    };

    /** Lookup fields on child rows that must be remapped on deploy. */
    private static final Map<String, Set<String>> CHILD_LOOKUP_FIELDS =
        new Map<String, Set<String>>{
            'Loan_Product_Accounting_Setup__c' => new Set<String>{
                'Business_Event__c', 'Default_Rule__c', 'User_Defined_Rule__c'
            },
            'Loan_Loss_Provisioning_Setup__c' => new Set<String>{
                'New_Class__c'
            },
            'Default_Commission_Hierarchy__c' => new Set<String>{
                'Default_Commission_Plan__c'
            }
        };

    /** Bare child api name → lookup field on the child that points back to Loan_Product__c. */
    private static final Map<String, String> CHILD_PARENT_FIELD = new Map<String, String>{
        'Loan_Product_Accounting_Setup__c'    => 'Loan_Product__c',
        'Loan_Loss_Provisioning_Setup__c'     => 'Loan_Product__c',
        'Loan_Payment_Spread__c'              => 'Loan_Product__c',
        'Product_Pre_Paid_Fees__c'            => 'Lending_Product__c',
        'Fee_Order__c'                        => 'Lending_Product__c',
        'Product_Amortization_Balance_Setup__c' => 'Lending_Product__c',
        'Periodic_Fee_Setup__c'               => 'Lending_Product__c',
        'Protect_Fee_Split__c'                => 'Lending_Product__c',
        'Default_Commission_Hierarchy__c'     => 'Lending_Product__c',
        'Loan_Product_Cycle__c'               => 'Loan_Product__c',
        'Loan_Approval_Prerequisites__c'      => 'Loan_Product__c',
        'clcommon__StepUp_Schedule__c'        => 'Loan_Product__c',
        'clcommon__Interest_Component__c'     => 'Loan_Product__c',
        'clcommon__Holiday_Schedule__c'       => 'Loan_Product__c'
    };

    /**
     * Main deploy entrypoint. Returns:
     *   { success, newProductId, summary: { reused: {Obj: count}, created: {Obj: count} } }
     * On error returns { success: false, errorMessage }.
     */
    public static Map<String, Object> deployProduct(Map<String, Object> payload) {
        if (payload == null) {
            return errorResponse('Empty payload');
        }
        Map<String, Object> editedProduct =
            (Map<String, Object>) payload.get('loanProduct');
        if (editedProduct == null) {
            return errorResponse('Payload missing loanProduct');
        }
        Map<String, Object> productFields =
            (Map<String, Object>) editedProduct.get('fields');
        if (productFields == null) {
            return errorResponse('Payload missing loanProduct.fields');
        }

        // `JSON.deserializeUntyped` returns Map<String,Object> / List<Object>.
        // Apex disallows direct casts to deeper generic shapes; we have to
        // rebuild the typed views one level at a time.
        Map<String, List<Map<String, Object>>> related =
            normalizeListOfMapMap((Map<String, Object>) payload.get('relatedObjects'));
        Map<String, Map<String, Object>> fees =
            normalizeMapOfMap((Map<String, Object>) payload.get('fees'));
        Map<String, List<Map<String, Object>>> children =
            normalizeListOfMapMap((Map<String, Object>) payload.get('children'));

        Map<String, Integer> reusedCounts  = new Map<String, Integer>();
        Map<String, Integer> createdCounts = new Map<String, Integer>();
        List<Map<String, Object>> renamedRecords = new List<Map<String, Object>>();

        // Source Id → target Id remap. Built up as we resolve references.
        Map<String, String> idRemap = new Map<String, String>();
        // Tracks which target parent Ids came from a fresh insert (vs. a reused
        // existing record). Junction children should only be inserted under
        // newly-inserted parents — reused parents already have their own.
        Set<String> insertedParentIds = new Set<String>();

        Savepoint sp = Database.setSavepoint();
        try {
            // ── Step A: standalone reference objects (match-by-Name + content) ────
            for (String objName : REFERENCE_OBJECTS_BY_NAME) {
                List<Map<String, Object>> records = collectReferenceRecords(objName, related, fees);
                if (records == null || records.isEmpty()) continue;

                processReferenceRecords(
                    objName, records, idRemap, reusedCounts, createdCounts,
                    renamedRecords, insertedParentIds, related, fees
                );
            }

            // ── Step B: Fee_Junction__c rows ─────────────────────────────────
            //    Insert junctions ONLY for fee sets we just created. Reused
            //    fee sets already carry their own junctions in the target org
            //    (and content-equality already proved the children match).
            insertFeeJunctions(related, idRemap, createdCounts, insertedParentIds);
            insertDelinquencyJunctions(related, idRemap, createdCounts, insertedParentIds);

            // ── Step C: Loan_Product__c with remapped lookup Ids ────────────
            // The portal stores Name at the wrapper level (editedProduct.Name),
            // not inside fields. Hoist it back in before insert so validation
            // rules like "Loan Product name cannot be blank" don't trip.
            Object editedName = editedProduct.get('Name');
            if (editedName != null && !productFields.containsKey('Name')) {
                productFields.put('Name', editedName);
            }
            SObject product = buildSObject('Loan_Product__c', productFields, idRemap, PRODUCT_LOOKUP_FIELDS);
            insert product;
            increment(createdCounts, 'Loan_Product__c');
            String newProductId = String.valueOf(product.Id);

            // The source product Id (so child rows pointing at it remap correctly).
            Object sourceProductIdObj = editedProduct.get('Id');
            if (sourceProductIdObj != null) {
                idRemap.put(String.valueOf(sourceProductIdObj), newProductId);
            }

            // ── Step D: Loan_Parameters__c — already in the related-objects
            //    bucket, but its lookup back to Loan_Product__c is on the
            //    Loan_Product__c side (Loan_Parameters__c.Loan_Product__c may
            //    or may not exist; the canonical link is product → params).
            //    Loan_Parameters was already match-by-Name'd in Step A.

            // ── Step E: child relationship rows (always insert) ─────────────
            if (children != null) {
                for (String childObj : children.keySet()) {
                    String parentField = CHILD_PARENT_FIELD.get(childObj);
                    if (parentField == null) continue; // unknown child, skip
                    // Other lookups on the child (e.g. Default_Rule__c) carry
                    // source-org Ids and must be remapped through idRemap.
                    // The parent lookup is intentionally NOT in this set:
                    // we set it to `newProductId` directly (a target-org Id),
                    // and including it would cause buildSObject to look it up
                    // in idRemap, find nothing, and skip the field — leaving
                    // the required master-detail empty on insert.
                    Set<String> childLookups = CHILD_LOOKUP_FIELDS.containsKey(childObj)
                        ? CHILD_LOOKUP_FIELDS.get(childObj)
                        : new Set<String>();

                    List<SObject> toInsert = new List<SObject>();
                    for (Map<String, Object> row : children.get(childObj)) {
                        Map<String, Object> rowFields = (Map<String, Object>) row.get('fields');
                        if (rowFields == null) continue;

                        // Force the parent lookup to the new product Id.
                        Map<String, Object> finalFields = new Map<String, Object>(rowFields);
                        finalFields.put(parentField, newProductId);

                        SObject rec = buildSObject(childObj, finalFields, idRemap, childLookups);
                        toInsert.add(rec);
                    }
                    if (!toInsert.isEmpty()) {
                        insert toInsert;
                        increment(createdCounts, childObj, toInsert.size());
                    }
                }
            }

            return new Map<String, Object>{
                'success'      => true,
                'newProductId' => newProductId,
                'summary'      => new Map<String, Object>{
                    'reused'  => reusedCounts,
                    'created' => createdCounts,
                    'renamed' => renamedRecords
                }
            };

        } catch (Exception e) {
            Database.rollback(sp);
            String msg = e.getMessage();
            if (String.isBlank(msg)) msg = e.getTypeName();
            String detail = e.getTypeName() + ': ' + msg;
            try {
                detail += ' | at line ' + e.getLineNumber() + ' | ' + e.getStackTraceString();
            } catch (Exception ignored) {}
            return errorResponse(detail);
        }
    }

    /** Pulls the records for an object out of related/fees buckets. */
    private static List<Map<String, Object>> collectReferenceRecords(
            String objName,
            Map<String, List<Map<String, Object>>> related,
            Map<String, Map<String, Object>> fees) {
        if (objName == 'Fee__c' && fees != null) {
            return new List<Map<String, Object>>(fees.values());
        }
        // Floating_Rate__c rows are embedded as children of Floating_Rate_Index__c
        // records. Collect them all into a flat list so processReferenceRecords
        // can register their Ids in idRemap.
        if (objName == 'Floating_Rate__c' && related != null) {
            List<Map<String, Object>> allRates = new List<Map<String, Object>>();
            List<Map<String, Object>> indexes = related.get('Floating_Rate_Index__c');
            if (indexes != null) {
                for (Map<String, Object> idx : indexes) {
                    Object children = idx.get('Floating_Rate__c');
                    if (children == null) continue;
                    for (Object c : (List<Object>) children) {
                        allRates.add((Map<String, Object>) c);
                    }
                }
            }
            return allRates;
        }
        if (related == null) return null;
        return related.get(objName);
    }

    /**
     * For each record in the list:
     *   1) Look up by Name in the target org.
     *   2) If a candidate matches the snapshot record's content (flat fields
     *      plus container children for Fee_Set / Delinquency_Set), reuse
     *      its Id (counts as `reused`).
     *   3) If candidates exist but none matches, insert with a unique
     *      `{Name}-Copy-N` suffix and use the new Id (counts as `renamed`).
     *   4) If no candidate exists at all, insert with the original Name
     *      (counts as `created`).
     *
     * For container records (Fee_Set, Delinquency_Set) the equality check
     * recurses into children. Children are only inserted when the parent
     * itself was inserted (newly-created path); for reused parents the
     * existing children are kept as-is.
     */
    private static void processReferenceRecords(
            String objName,
            List<Map<String, Object>> records,
            Map<String, String> idRemap,
            Map<String, Integer> reusedCounts,
            Map<String, Integer> createdCounts,
            List<Map<String, Object>> renamedRecords,
            Set<String> insertedParentIds,
            Map<String, List<Map<String, Object>>> snapshotRelated,
            Map<String, Map<String, Object>> snapshotFees) {

        // Names we need to query in the target org.
        Set<String> namesToQuery = new Set<String>();
        for (Map<String, Object> r : records) {
            Object nm = r.get('Name');
            if (nm != null && String.isNotBlank(String.valueOf(nm))) {
                namesToQuery.add(String.valueOf(nm));
            }
        }

        // candidatesByName: Name → all target records that share that Name
        // (including their full field set so we can run equality checks).
        Map<String, List<SObject>> candidatesByName = new Map<String, List<SObject>>();
        if (!namesToQuery.isEmpty()) {
            try {
                List<String> allFields = getQueryableFields(objName);
                String soql = 'SELECT ' + String.join(allFields, ', ') +
                              ' FROM ' + resolveObjectName(objName) +
                              ' WHERE Name IN :namesToQuery';
                for (SObject rec : Database.query(soql)) {
                    String nm = String.valueOf(rec.get('Name'));
                    if (!candidatesByName.containsKey(nm)) {
                        candidatesByName.put(nm, new List<SObject>());
                    }
                    candidatesByName.get(nm).add(rec);
                }
            } catch (Exception ignored) {
                // Object may not have a queryable Name (junctions). All records
                // fall through to insert with no candidates.
            }
        }

        // Pre-load container children for any candidates if this is a container type.
        // Group children by **target parent Id** (string) so we can run equality
        // by Id later. Keep the children as their populated-fields-as-map view
        // so namespace prefixes don't confuse the lookup.
        Map<String, List<Map<String, Object>>> candidateContainerChildrenIdx =
            new Map<String, List<Map<String, Object>>>();
        if (CONTAINER_CHILD_OBJECT.containsKey(objName) && !candidatesByName.isEmpty()) {
            String childObj = CONTAINER_CHILD_OBJECT.get(objName);
            String parentRefField = CONTAINER_CHILD_PARENT_FIELD.get(objName);
            String linkedRefField = CONTAINER_CHILD_LINKED_FIELD.get(objName);
            String parentRefResolved = resolveFieldOnObject(childObj, parentRefField);
            String linkedRefResolved = linkedRefField == 'Id'
                ? 'Id'
                : resolveFieldOnObject(childObj, linkedRefField);
            Set<Id> candidateIds = new Set<Id>();
            for (List<SObject> bucket : candidatesByName.values()) {
                for (SObject c : bucket) candidateIds.add((Id) c.get('Id'));
            }
            try {
                String childSoql = 'SELECT Id, ' + parentRefResolved + ', ' + linkedRefResolved +
                                   ' FROM ' + resolveObjectName(childObj) +
                                   ' WHERE ' + parentRefResolved + ' IN :candidateIds';
                for (SObject c : Database.query(childSoql)) {
                    // indexPopulated lets us read fields by bare name regardless
                    // of whether the runtime stored them as `w22loan__foo__c`.
                    Map<String, Object> idx = indexPopulated(c.getPopulatedFieldsAsMap());
                    Object parentIdObj = idx.get(parentRefField.toLowerCase());
                    if (parentIdObj == null) continue;
                    String parentKey = String.valueOf(parentIdObj);
                    if (!candidateContainerChildrenIdx.containsKey(parentKey)) {
                        candidateContainerChildrenIdx.put(parentKey, new List<Map<String, Object>>());
                    }
                    candidateContainerChildrenIdx.get(parentKey).add(idx);
                }
            } catch (Exception ignored) {}
        }

        // For each snapshot record, decide reuse / rename / create.
        List<SObject>             toInsert       = new List<SObject>();
        List<Map<String, Object>> insertSrcs     = new List<Map<String, Object>>();
        List<String>              insertModes    = new List<String>(); // 'created' or 'renamed'
        List<String>              insertOrigNames= new List<String>();

        for (Map<String, Object> r : records) {
            Object srcIdObj = r.get('Id');
            if (srcIdObj == null) continue;
            String srcId = String.valueOf(srcIdObj);

            Object nm = r.get('Name');
            String name = nm == null ? null : String.valueOf(nm);

            // 1) Try reuse by matching content.
            if (name != null && candidatesByName.containsKey(name)) {
                Id matchedId = pickMatchingCandidate(
                    objName, r, candidatesByName.get(name),
                    candidateContainerChildrenIdx, idRemap,
                    snapshotRelated, snapshotFees
                );
                if (matchedId != null) {
                    idRemap.put(srcId, String.valueOf(matchedId));
                    increment(reusedCounts, objName);
                    continue;
                }
            }

            // 2) No match. Build a row to insert. Suffix the Name if it's taken.
            Map<String, Object> rowFields = (Map<String, Object>) r.get('fields');
            if (rowFields == null) rowFields = new Map<String, Object>();
            rowFields = new Map<String, Object>(rowFields);

            String mode = 'created';
            String finalName = name;
            if (name != null && candidatesByName.containsKey(name)) {
                // Name collides but content differs → suffix.
                finalName = nextAvailableSuffixedName(objName, name);
                mode = 'renamed';
            }
            if (finalName != null) {
                rowFields.put('Name', finalName);
            }

            Set<String> objLookups = RELATED_LOOKUP_FIELDS.containsKey(objName)
                ? RELATED_LOOKUP_FIELDS.get(objName)
                : new Set<String>();
            SObject rec = buildSObject(objName, rowFields, idRemap, objLookups);
            toInsert.add(rec);
            insertSrcs.add(r);
            insertModes.add(mode);
            insertOrigNames.add(name);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Integer i = 0; i < toInsert.size(); i++) {
                String srcId = String.valueOf(insertSrcs[i].get('Id'));
                String newId = String.valueOf(toInsert[i].Id);
                idRemap.put(srcId, newId);
                insertedParentIds.add(newId);
                String mode = insertModes[i];
                if (mode == 'renamed') {
                    increment(createdCounts, objName); // it IS still created — just under a new name
                    Map<String, Object> entry = new Map<String, Object>{
                        'object' => objName,
                        'fromName' => insertOrigNames[i],
                        'toName'   => String.valueOf(toInsert[i].get('Name'))
                    };
                    renamedRecords.add(entry);
                } else {
                    increment(createdCounts, objName);
                }
            }
        }
    }

    /**
     * Walks the candidates and returns the Id of the first one whose content
     * matches the snapshot record (flat fields + container children).
     * Returns null if no candidate matches.
     */
    private static Id pickMatchingCandidate(
            String objName,
            Map<String, Object> snapshotRecord,
            List<SObject> candidates,
            Map<String, List<Map<String, Object>>> candidateContainerChildrenIdx,
            Map<String, String> idRemap,
            Map<String, List<Map<String, Object>>> snapshotRelated,
            Map<String, Map<String, Object>> snapshotFees) {

        Map<String, Object> snapshotFields =
            (Map<String, Object>) snapshotRecord.get('fields');
        if (snapshotFields == null) snapshotFields = new Map<String, Object>();

        Set<String> lookupFieldsForObj = LOOKUP_FIELDS_BY_OBJECT.containsKey(objName)
            ? LOOKUP_FIELDS_BY_OBJECT.get(objName)
            : new Set<String>();

        for (SObject cand : candidates) {
            if (!fieldsEqual(snapshotFields, cand, lookupFieldsForObj, idRemap)) continue;

            // Container check: children must equal too.
            if (CONTAINER_CHILD_OBJECT.containsKey(objName)) {
                String candKey = String.valueOf(cand.get('Id'));
                List<Map<String, Object>> targetChildren =
                    candidateContainerChildrenIdx.containsKey(candKey)
                        ? candidateContainerChildrenIdx.get(candKey)
                        : new List<Map<String, Object>>();
                if (!containerChildrenEqual(
                        objName, snapshotRecord, targetChildren, idRemap,
                        snapshotRelated, snapshotFees)) continue;
            }
            return (Id) cand.get('Id');
        }
        return null;
    }

    /**
     * Compares snapshot field values against a target SObject for equality.
     * Lookup fields are compared against `idRemap[snapshotValue]` since the
     * target stores a target-org Id while the snapshot stores a source-org Id.
     */
    private static Boolean fieldsEqual(
            Map<String, Object> snapshotFields,
            SObject target,
            Set<String> lookupFields,
            Map<String, String> idRemap) {

        // Build an indexed view of the target record so we can look up by bare name.
        Map<String, Object> targetIdx = indexPopulated(target.getPopulatedFieldsAsMap());

        // For each snapshot field, the target must carry an equivalent value.
        for (String f : snapshotFields.keySet()) {
            if (f == 'Name' || f == 'Id') continue;
            Object snapVal = snapshotFields.get(f);
            Object tgtVal  = targetIdx.get(f.toLowerCase());

            if (lookupFields.contains(f) && snapVal != null) {
                String mapped = idRemap.get(String.valueOf(snapVal));
                if (mapped == null) return false; // can't compare without remap
                if (tgtVal == null || !mapped.equals(String.valueOf(tgtVal))) return false;
                continue;
            }

            if (!valuesEqual(snapVal, tgtVal)) return false;
        }

        // And the target must not have any populated field the snapshot doesn't.
        // System / audit fields are excluded from getQueryableFields, so this is fair.
        // Build a lowercase set of bare snapshot keys to compare against.
        Set<String> snapshotKeysCi = new Set<String>();
        for (String sk : snapshotFields.keySet()) {
            snapshotKeysCi.add(sk.toLowerCase());
        }
        for (String tk : targetIdx.keySet()) {
            if (tk == 'id' || tk == 'name') continue;
            // Standard SF system fields aren't carried in the snapshot.
            if (SYSTEM_FIELD_SKIP.contains(tk)) continue;
            // `targetIdx` carries both prefixed (`w22loan__foo__c`) and bare
            // (`foo__c`) forms. Strip any namespace prefix before checking
            // against the snapshot's bare keys so package-namespaced field
            // names don't trigger false-mismatches on same-org deploys.
            String tkBare = tk;
            Integer dunder = tk.indexOf('__');
            if (dunder > 0 && tk.endsWith('__c') && tk.indexOf('__c') > dunder) {
                tkBare = tk.substring(dunder + 2);
            }
            if (snapshotKeysCi.contains(tkBare) || snapshotKeysCi.contains(tk)) continue;
            Object tv = targetIdx.get(tk);
            if (isAbsent(tv)) continue;
            // Boolean false / numeric 0 on the target are package defaults
            // that the snapshot may or may not have captured. Treat them as
            // equivalent to "snapshot doesn't carry this field" so we don't
            // false-mismatch on records that are otherwise identical.
            if (tv instanceof Boolean && Boolean.valueOf(tv) == false) continue;
            if (tv instanceof Decimal && Decimal.valueOf(String.valueOf(tv)) == 0) continue;
            if (tv instanceof Integer && (Integer) tv == 0) continue;
            return false;
        }
        return true;
    }

    /** Treat null, "", and whitespace-only strings as absent. */
    private static Boolean isAbsent(Object v) {
        if (v == null) return true;
        if (v instanceof String && String.isBlank((String) v)) return true;
        return false;
    }

    /** Numeric-tolerant, type-coerced equality. */
    private static Boolean valuesEqual(Object a, Object b) {
        if (isAbsent(a) && isAbsent(b)) return true;
        // Salesforce checkbox semantics: an unset Boolean field round-trips as
        // either `false` or absent depending on the API path. Treat them as
        // equivalent so equality doesn't false-mismatch on Boolean defaults.
        if (a instanceof Boolean && Boolean.valueOf(a) == false && isAbsent(b)) return true;
        if (b instanceof Boolean && Boolean.valueOf(b) == false && isAbsent(a)) return true;
        // Numeric default similar story: `0` from a Number field that the
        // package treats as the implicit default round-trips inconsistently.
        if (a instanceof Decimal && Decimal.valueOf(String.valueOf(a)) == 0 && isAbsent(b)) return true;
        if (b instanceof Decimal && Decimal.valueOf(String.valueOf(b)) == 0 && isAbsent(a)) return true;
        if (a instanceof Integer && (Integer) a == 0 && isAbsent(b)) return true;
        if (b instanceof Integer && (Integer) b == 0 && isAbsent(a)) return true;
        if (isAbsent(a) || isAbsent(b)) return false;
        if (a instanceof Decimal || a instanceof Double || a instanceof Integer ||
            b instanceof Decimal || b instanceof Double || b instanceof Integer) {
            try {
                Decimal da = Decimal.valueOf(String.valueOf(a)).setScale(10, System.RoundingMode.HALF_UP);
                Decimal db = Decimal.valueOf(String.valueOf(b)).setScale(10, System.RoundingMode.HALF_UP);
                return da == db;
            } catch (Exception e) {
                // Fall through to string compare.
            }
        }
        return String.valueOf(a) == String.valueOf(b);
    }

    /**
     * Container equality: every snapshot child junction must correspond to a
     * target junction whose linked record equals the snapshot's, AND the
     * target must not carry any extra junctions the snapshot doesn't have.
     *
     * `targetChildren` is a list of indexed-populated maps (bare-name keyed)
     * so we can read fields by their bare api name regardless of namespace.
     */
    private static Boolean containerChildrenEqual(
            String containerObj,
            Map<String, Object> snapshotContainer,
            List<Map<String, Object>> targetChildren,
            Map<String, String> idRemap,
            Map<String, List<Map<String, Object>>> snapshotRelated,
            Map<String, Map<String, Object>> snapshotFees) {

        String childObj          = CONTAINER_CHILD_OBJECT.get(containerObj);
        String linkedField       = CONTAINER_CHILD_LINKED_FIELD.get(containerObj);

        // Snapshot junction list — lives on the container under the bare child api name.
        Object junctionsObj = snapshotContainer.get(childObj);
        List<Object> snapshotJunctions = junctionsObj == null
            ? new List<Object>()
            : (List<Object>) junctionsObj;

        if (snapshotJunctions.size() != targetChildren.size()) return false;

        Boolean isDirectChild = linkedField == 'Id';

        // Build a multiset of target linked Ids.
        // For junction-style: read the field pointing at the content leaf (e.g. Fee__c).
        // For direct-child: read the child's own Id.
        List<String> targetLinkedIds = new List<String>();
        String linkedFieldLower = linkedField.toLowerCase();
        for (Map<String, Object> t : targetChildren) {
            Object v = isDirectChild ? t.get('id') : t.get(linkedFieldLower);
            if (v != null) targetLinkedIds.add(String.valueOf(v));
        }

        // For each snapshot child/junction, match it to a target entry.
        for (Object j : snapshotJunctions) {
            Map<String, Object> jMap = (Map<String, Object>) j;
            if (isDirectChild) {
                // Direct child: match by the child's snapshot Id remapped to target Id.
                Object srcId = jMap.get('Id');
                if (srcId == null) return false;
                String mapped = idRemap.get(String.valueOf(srcId));
                if (mapped == null) return false;
                Integer idx = targetLinkedIds.indexOf(mapped);
                if (idx < 0) return false;
                targetLinkedIds.remove(idx);
            } else {
                // Junction: match by the linked content field (Fee__c, Delinquency_Interval__c).
                Map<String, Object> jFields = (Map<String, Object>) jMap.get('fields');
                if (jFields == null) return false;
                Object linkedSrcId = jFields.get(linkedField);
                if (linkedSrcId == null) return false;
                String mapped = idRemap.get(String.valueOf(linkedSrcId));
                if (mapped == null) return false;
                Integer idx = targetLinkedIds.indexOf(mapped);
                if (idx < 0) return false;
                targetLinkedIds.remove(idx);
            }
        }
        return targetLinkedIds.isEmpty();
    }

    /**
     * Returns `{name}-Copy-N` for the smallest N (>=1) not already present on
     * any target record. Falls back to `{name}-Copy-{epoch}` if the SOQL fails.
     */
    private static String nextAvailableSuffixedName(String objName, String baseName) {
        String namePattern = baseName + '-Copy-%';
        Set<Integer> usedSuffixes = new Set<Integer>();
        try {
            for (SObject rec : Database.query(
                    'SELECT Name FROM ' + resolveObjectName(objName) + ' WHERE Name LIKE :namePattern')) {
                String nm = String.valueOf(rec.get('Name'));
                Integer dashIdx = nm.lastIndexOf('-');
                if (dashIdx < 0) continue;
                String tail = nm.substring(dashIdx + 1);
                try {
                    usedSuffixes.add(Integer.valueOf(tail));
                } catch (Exception ignored) {}
            }
        } catch (Exception e) {
            return baseName + '-Copy-' + String.valueOf(System.currentTimeMillis());
        }
        Integer n = 1;
        while (usedSuffixes.contains(n)) n++;
        return baseName + '-Copy-' + String.valueOf(n);
    }

    // ─── Container + per-object equality config ────────────────────────────

    /**
     * Container parent → child object key used in the snapshot map.
     * For junction-style containers: Fee_Set → Fee_Junction__c (which links to Fee__c).
     * For direct-child containers: Floating_Rate_Index → Floating_Rate__c (direct child).
     */
    private static final Map<String, String> CONTAINER_CHILD_OBJECT = new Map<String, String>{
        'Fee_Set__c'              => 'Fee_Junction__c',
        'Delinquency_Set__c'      => 'Delinquency_Set_Junction__c',
        'Floating_Rate_Index__c'  => 'Floating_Rate__c'
    };
    /** Container child → field name that points back to the parent container. */
    private static final Map<String, String> CONTAINER_CHILD_PARENT_FIELD = new Map<String, String>{
        'Fee_Set__c'              => 'Fee_Set__c',
        'Delinquency_Set__c'      => 'Delinquency_Set__c',
        'Floating_Rate_Index__c'  => 'Floating_Rate_Index__c'
    };
    /**
     * Container child → field name used to identify a "linked" content record
     * for junction-style containers (Fee__c, Delinquency_Interval__c).
     * For direct-child containers the child IS the content; use 'Id'.
     */
    private static final Map<String, String> CONTAINER_CHILD_LINKED_FIELD = new Map<String, String>{
        'Fee_Set__c'              => 'Fee__c',
        'Delinquency_Set__c'      => 'Delinquency_Interval__c',
        'Floating_Rate_Index__c'  => 'Id'
    };
    /** Container child → object that the linked field references. */
    private static final Map<String, String> CONTAINER_CHILD_LINKED_TARGET = new Map<String, String>{
        'Fee_Set__c'              => 'Fee__c',
        'Delinquency_Set__c'      => 'Delinquency_Interval__c',
        'Floating_Rate_Index__c'  => 'Floating_Rate__c'
    };

    /** Lookup fields per object type — values are remapped through idRemap on equality. */
    private static final Map<String, Set<String>> LOOKUP_FIELDS_BY_OBJECT = new Map<String, Set<String>>{
        'Loan_Parameters__c' => new Set<String>{ 'Clawback_Rule_Set__c' },
        'Fee_Set__c'         => new Set<String>{},
        'Delinquency_Set__c' => new Set<String>{},
        'MF_Account__c'      => new Set<String>{ 'Account_Type__c', 'Parent_Account__c' }
    };

    /**
     * Inserts Fee_Junction__c rows only under Fee_Set parents that were freshly
     * created in this deploy. Reused fee sets already have their own junctions
     * in the target org (and content equality already verified they match).
     */
    private static void insertFeeJunctions(
            Map<String, List<Map<String, Object>>> related,
            Map<String, String> idRemap,
            Map<String, Integer> createdCounts,
            Set<String> insertedParentIds) {
        insertContainerJunctions(
            'Fee_Set__c', 'Fee_Junction__c',
            new Set<String>{ 'Fee__c', 'Fee_Set__c' },
            related, idRemap, createdCounts, insertedParentIds
        );
    }

    /** Same idea as insertFeeJunctions, but for Delinquency_Set → Delinquency_Set_Junction. */
    private static void insertDelinquencyJunctions(
            Map<String, List<Map<String, Object>>> related,
            Map<String, String> idRemap,
            Map<String, Integer> createdCounts,
            Set<String> insertedParentIds) {
        insertContainerJunctions(
            'Delinquency_Set__c', 'Delinquency_Set_Junction__c',
            new Set<String>{ 'Delinquency_Set__c', 'Delinquency_Interval__c' },
            related, idRemap, createdCounts, insertedParentIds
        );
    }

    /** Shared body for both container junction inserts. */
    private static void insertContainerJunctions(
            String parentObj,
            String junctionObj,
            Set<String> junctionLookups,
            Map<String, List<Map<String, Object>>> related,
            Map<String, String> idRemap,
            Map<String, Integer> createdCounts,
            Set<String> insertedParentIds) {
        if (related == null) return;
        List<Map<String, Object>> parents = related.get(parentObj);
        if (parents == null) return;

        List<SObject> toInsert = new List<SObject>();
        for (Map<String, Object> parent : parents) {
            Object srcParentIdObj = parent.get('Id');
            if (srcParentIdObj == null) continue;
            String mappedParent = idRemap.get(String.valueOf(srcParentIdObj));
            if (mappedParent == null) continue;
            // Only attach junctions if the parent was freshly inserted.
            if (!insertedParentIds.contains(mappedParent)) continue;

            Object junctionsObj = parent.get(junctionObj);
            if (junctionsObj == null) continue;
            List<Object> junctions = (List<Object>) junctionsObj;
            for (Object jObj : junctions) {
                Map<String, Object> junction = (Map<String, Object>) jObj;
                Map<String, Object> jFields = (Map<String, Object>) junction.get('fields');
                if (jFields == null) continue;
                SObject rec = buildSObject(junctionObj, jFields, idRemap, junctionLookups);
                toInsert.add(rec);
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
            increment(createdCounts, junctionObj, toInsert.size());
        }
    }

    /**
     * Schema.getGlobalDescribe() keys SObjects by their fully-qualified API name,
     * which for managed-package types means `w22loan__Foo__c` even though our
     * snapshots use the bare `Foo__c`. This resolver tries the bare name first
     * and then probable namespace prefixes so deploy can build SObjects without
     * the caller knowing which org the package landed in.
     */
    private static Map<String, Schema.SObjectType> sobjectTypeCache = null;
    private static Schema.SObjectType resolveSObjectType(String objName) {
        if (sobjectTypeCache == null) sobjectTypeCache = Schema.getGlobalDescribe();
        if (sobjectTypeCache.containsKey(objName)) return sobjectTypeCache.get(objName);
        // Try lower-case (some Apex returns lowercased keys).
        String lower = objName.toLowerCase();
        if (sobjectTypeCache.containsKey(lower)) return sobjectTypeCache.get(lower);
        // Already-prefixed names should match above; only try prefixing bare names.
        Integer dunder = objName.indexOf('__');
        Boolean isAlreadyPrefixed = dunder > 0 && objName.indexOf('__c') > dunder;
        if (!isAlreadyPrefixed) {
            for (String ns : getNamespacePrefixes()) {
                if (String.isBlank(ns)) continue; // unmanaged — no prefix to try
                Schema.SObjectType t = sobjectTypeCache.get(ns + objName);
                if (t != null) return t;
                t = sobjectTypeCache.get((ns + objName).toLowerCase());
                if (t != null) return t;
            }
        }
        return null;
    }

    /**
     * Builds an SObject of the given type, populating fields from the source
     * map. For any field listed in `lookupFields`, the value is treated as a
     * source-org Id and remapped via `idRemap` (skipped if not in the map).
     * Field names are tried bare first, then with `w22loan__` / `clcommon__`
     * prefixes — managed-package fields on installed objects come back with
     * the namespace prefix and `SObject.put()` rejects the bare name.
     */
    private static SObject buildSObject(
            String objName,
            Map<String, Object> fields,
            Map<String, String> idRemap,
            Set<String> lookupFields) {
        Schema.SObjectType t = resolveSObjectType(objName);
        if (t == null) {
            throw new DeployException('Unknown object: ' + objName);
        }
        Schema.DescribeSObjectResult dr = t.getDescribe();
        Map<String, Schema.SObjectField> describeFieldMap = dr.fields.getMap();

        SObject rec = t.newSObject();

        for (String f : fields.keySet()) {
            if (f == 'Id') continue;
            Object val = fields.get(f);
            if (val == null) continue;
            if (val instanceof String && String.isBlank((String) val)) continue;

            // Remap lookups through the source→target Id table.
            if (lookupFields != null && lookupFields.contains(f)) {
                String srcId = String.valueOf(val);
                String targetId = idRemap.get(srcId);
                if (targetId == null) {
                    // If we don't have a remapping, leave the field unset
                    // rather than blowing up with INVALID_CROSS_REFERENCE_KEY.
                    continue;
                }
                val = targetId;
            }

            // Resolve the actual field name on this org (bare vs prefixed).
            String resolvedField = resolveFieldName(describeFieldMap, f);
            if (resolvedField == null) continue; // genuinely unknown on this org

            // Skip fields Salesforce considers non-editable on insert
            // (formula, auto-number, rollup summary, system-managed, etc.).
            // Without this, `rec.put` throws SObjectException for any such
            // field carried in the snapshot, killing the deploy.
            Schema.DescribeFieldResult fr = describeFieldMap.get(resolvedField).getDescribe();
            if (!fr.isCreateable()) continue;

            rec.put(resolvedField, val);
        }
        return rec;
    }

    /**
     * Returns the canonical field name for `apiName` on the given describe map,
     * trying bare → `w22loan__` → `clcommon__`. Returns null if no variant
     * matches a real field (caller should skip).
     */
    private static String resolveFieldName(
            Map<String, Schema.SObjectField> describeFieldMap, String apiName) {
        String lower = apiName.toLowerCase();
        if (describeFieldMap.containsKey(lower)) {
            return describeFieldMap.get(lower).getDescribe().getName();
        }
        // Already-prefixed name? Skip the prefix-prepend attempts.
        Integer dunder = apiName.indexOf('__');
        Boolean isAlreadyPrefixed = dunder > 0 && apiName.indexOf('__c') > dunder;
        if (!isAlreadyPrefixed) {
            for (String ns : getNamespacePrefixes()) {
                if (String.isBlank(ns)) continue;
                String key = (ns + apiName).toLowerCase();
                if (describeFieldMap.containsKey(key)) {
                    return describeFieldMap.get(key).getDescribe().getName();
                }
            }
        }
        return null;
    }

    private static void increment(Map<String, Integer> counts, String key) {
        increment(counts, key, 1);
    }

    private static void increment(Map<String, Integer> counts, String key, Integer delta) {
        Integer cur = counts.containsKey(key) ? counts.get(key) : 0;
        counts.put(key, cur + delta);
    }

    private static Map<String, Object> errorResponse(String message) {
        return new Map<String, Object>{
            'success'      => false,
            'errorMessage' => message
        };
    }

    /**
     * Converts the untyped JSON shape `Map<String, List<Object>>` into the
     * typed `Map<String, List<Map<String, Object>>>` the deploy pipeline
     * expects. Skips entries whose values aren't list-of-map.
     */
    private static Map<String, List<Map<String, Object>>> normalizeListOfMapMap(
            Map<String, Object> raw) {
        Map<String, List<Map<String, Object>>> out =
            new Map<String, List<Map<String, Object>>>();
        if (raw == null) return out;
        for (String k : raw.keySet()) {
            Object v = raw.get(k);
            if (!(v instanceof List<Object>)) continue;
            List<Map<String, Object>> bucket = new List<Map<String, Object>>();
            for (Object item : (List<Object>) v) {
                if (item instanceof Map<String, Object>) {
                    bucket.add((Map<String, Object>) item);
                }
            }
            out.put(k, bucket);
        }
        return out;
    }

    /**
     * Converts the untyped JSON shape `Map<String, Map<String, Object>>` from
     * `JSON.deserializeUntyped` into a typed map. Skips entries whose values
     * aren't maps.
     */
    private static Map<String, Map<String, Object>> normalizeMapOfMap(
            Map<String, Object> raw) {
        Map<String, Map<String, Object>> out = new Map<String, Map<String, Object>>();
        if (raw == null) return out;
        for (String k : raw.keySet()) {
            Object v = raw.get(k);
            if (v instanceof Map<String, Object>) {
                out.put(k, (Map<String, Object>) v);
            }
        }
        return out;
    }

    public class DeployException extends Exception {}
}
