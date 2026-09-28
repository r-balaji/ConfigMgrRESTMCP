/**
 * MCP tool: diff_record.
 *
 * Diagnostic explaining why a record's content-equality check would or
 * wouldn't match against other records with the same Name. Input/Output
 * are inner classes — see ListProductsAction header for the empirical
 * confirmation.
 */
global with sharing class DiffRecordAction {

    global class Input {
        @InvocableVariable(
            label='Object Name'
            description='API name of the SObject to diff (e.g. "Fee_Set__c", "Delinquency_Set__c"). Bare or namespace-prefixed both work.'
            required=true
        )
        global String objectName;

        @InvocableVariable(
            label='Record Id'
            description='Salesforce Id (15- or 18-char) of the record to compare against same-Name candidates in the org.'
            required=true
        )
        global String recordId;
    }

    global class Output {
        @InvocableVariable(
            label='Diff JSON'
            description='Per-candidate mismatch report. Top-level keys: object, recordId, sourceRecord, candidates. Each candidate entry shows whether it matches and lists field-level mismatches.'
        )
        global String diffJson;
    }

    @InvocableMethod(
        label='Diff Record'
        description='Diagnostic tool for understanding deploy equality. Returns a per-candidate mismatch report explaining why a record would or would not match against itself and other records sharing its Name. Useful when debugging why a deploy is producing "<name>-Copy-N" renames for records that look identical to a human.'
        callout=false
    )
    global static List<Output> run(List<Input> requests) {
        List<Output> results = new List<Output>();
        for (Input req : requests) {
            Output o = new Output();
            if (String.isBlank(req.objectName) || String.isBlank(req.recordId)) {
                o.diffJson = JSON.serialize(new Map<String, Object>{
                    'success'      => false,
                    'errorMessage' => 'objectName and recordId are both required'
                });
            } else {
                o.diffJson = JSON.serialize(
                    LoanProductConfigService.diffRecord(req.objectName, req.recordId)
                );
            }
            results.add(o);
        }
        return results;
    }
}
