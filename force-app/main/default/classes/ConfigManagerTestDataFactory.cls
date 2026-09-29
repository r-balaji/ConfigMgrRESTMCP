/**
 * Test data factory for the Config Manager REST and MCP entry points.
 *
 * The implementation resolves the lending object and fields at runtime so the
 * tests work both in the w22loan development org and in a subscriber org where
 * the lending package fields carry a namespace prefix.
 */
@IsTest
public with sharing class ConfigManagerTestDataFactory {

    public static List<SObject> createLoanProducts(Integer count, Boolean doInsert) {
        Assert.isTrue(count > 0, 'count must be greater than zero');

        Schema.SObjectType productType = resolveType('Loan_Product__c');
        if (productType == null) {
            return new List<SObject>();
        }
        disableLoanProductTriggerForCurrentUser();

        List<SObject> products = new List<SObject>();
        String uniqueKey = String.valueOf(DateTime.now().getTime());
        for (Integer index = 0; index < count; index++) {
            SObject product = productType.newSObject();
            putIfCreateable(product, 'Name', 'Config Manager Test ' + uniqueKey + ' ' + index);
            putPreferredPicklist(product, 'Loan_Product_Type__c', 'Loan');
            putPreferredPicklist(product, 'Status__c', 'Active');
            products.add(product);
        }

        if (doInsert) {
            insert products;
        }
        return products;
    }

    public static SObject createLoanProduct(Boolean doInsert) {
        List<SObject> products = createLoanProducts(1, doInsert);
        return products.isEmpty() ? null : products[0];
    }

    public static Boolean hasLoanProductSchema() {
        return resolveType('Loan_Product__c') != null;
    }

    public static Id getOnlyLoanProductId() {
        Schema.SObjectType productType = resolveType('Loan_Product__c');
        Assert.isNotNull(productType, 'Loan_Product__c must be available to run these tests');
        List<SObject> products = Database.query(
            'SELECT Id FROM ' + productType.getDescribe().getName() + ' LIMIT 1'
        );
        Assert.areEqual(1, products.size(), 'Expected the test setup to create one loan product');
        return (Id) products[0].get('Id');
    }

    public static Map<String, Object> createDeployPayload(String productName) {
        return new Map<String, Object>{
            'loanProduct' => new Map<String, Object>{
                'Name' => productName,
                'fields' => new Map<String, Object>{
                    'Loan_Product_Type__c' => 'Loan',
                    'Status__c' => 'Active'
                }
            },
            'relatedObjects' => new Map<String, Object>(),
            'children' => new Map<String, Object>(),
            'fees' => new Map<String, Object>()
        };
    }

    /**
     * The lending package exposes a hierarchy setting specifically for
     * disabling individual triggers in tests and data-load operations. A
     * user-level setting keeps the bypass scoped to this isolated test user.
     */
    private static void disableLoanProductTriggerForCurrentUser() {
        Schema.SObjectType settingType = resolveType('Trigger_Parameters__c');
        if (settingType == null) {
            return;
        }

        SObject setting = settingType.newSObject();
        putIfCreateable(setting, 'SetupOwnerId', UserInfo.getUserId());
        putIfCreateable(setting, 'Disable_Loan_Prd_Trigger__c', true);
        insert setting;
    }

    private static Schema.SObjectType resolveType(String bareName) {
        Map<String, Schema.SObjectType> allTypes = Schema.getGlobalDescribe();
        String bareLower = bareName.toLowerCase();
        for (String apiName : allTypes.keySet()) {
            String apiLower = apiName.toLowerCase();
            if (apiLower == bareLower || apiLower.endsWith('__' + bareLower)) {
                return allTypes.get(apiName);
            }
        }
        return null;
    }

    private static void putIfCreateable(SObject record, String bareField, Object value) {
        Schema.SObjectField fieldToken = resolveField(record.getSObjectType(), bareField);
        if (fieldToken != null && fieldToken.getDescribe().isCreateable()) {
            record.put(fieldToken.getDescribe().getName(), value);
        }
    }

    private static void putPreferredPicklist(
            SObject record,
            String bareField,
            String preferredValue) {
        Schema.SObjectField fieldToken = resolveField(record.getSObjectType(), bareField);
        if (fieldToken == null || !fieldToken.getDescribe().isCreateable()) {
            return;
        }

        String valueToUse;
        for (Schema.PicklistEntry entry : fieldToken.getDescribe().getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            if (entry.getValue() == preferredValue) {
                valueToUse = preferredValue;
                break;
            }
            if (valueToUse == null) {
                valueToUse = entry.getValue();
            }
        }
        if (valueToUse != null) {
            record.put(fieldToken.getDescribe().getName(), valueToUse);
        }
    }

    private static Schema.SObjectField resolveField(
            Schema.SObjectType objectType,
            String bareField) {
        String bareLower = bareField.toLowerCase();
        for (Schema.SObjectField fieldToken :
                objectType.getDescribe().fields.getMap().values()) {
            String apiLower = fieldToken.getDescribe().getName().toLowerCase();
            if (apiLower == bareLower || apiLower.endsWith('__' + bareLower)) {
                return fieldToken;
            }
        }
        return null;
    }
}
