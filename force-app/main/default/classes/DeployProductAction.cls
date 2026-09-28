/**
 * MCP tool: deploy_product.
 *
 * Wraps `LoanProductConfigService.deployProduct(payload)`. Input/Output are
 * inner classes — see ListProductsAction header for the empirical confirmation.
 *
 * This is the only destructive tool in the set — mark it destructiveHint=true
 * on the MCP Server Setup page so clients can prompt the user for confirmation
 * before invocation.
 */
global with sharing class DeployProductAction {

    global class Input {
        @InvocableVariable(
            label='Payload JSON'
            description='The product graph to deploy, JSON-stringified. Shape: { loanProduct, relatedObjects, children, fees } — same as get_product returns. Pass through verbatim with whatever edits you want applied; reference records are reused by Name+content match, renamed to "<name>-Copy-N" on content divergence, or freshly inserted when no match exists.'
            required=true
        )
        global String payloadJson;
    }

    global class Output {
        @InvocableVariable(
            label='Result JSON'
            description='Deploy result. Shape: { success, newProductId, summary: { reused, created, renamed } } on success, or { success: false, errorMessage } on failure.'
        )
        global String resultJson;
    }

    @InvocableMethod(
        label='Deploy Loan Product'
        description='Deploy a (possibly edited) Golden Copy product graph to the connected Salesforce org. Reference records (Fee_Set__c, Delinquency_Set__c, MF_Account__c, MF_Account_Type__c, etc.) are matched by Name and full content — reused if identical, renamed to "<name>-Copy-N" if a Name collides with different content, or freshly inserted when no candidate exists. The new Loan_Product__c Id is returned on success. THIS IS A DESTRUCTIVE OPERATION that creates records in the target org; prompt the user for confirmation before invoking.'
        callout=false
    )
    global static List<Output> run(List<Input> requests) {
        List<Output> results = new List<Output>();
        for (Input req : requests) {
            Output o = new Output();
            if (String.isBlank(req.payloadJson)) {
                o.resultJson = JSON.serialize(new Map<String, Object>{'success' => false, 'errorMessage' => 'payloadJson is required'});
                results.add(o);
                continue;
            }
            try {
                Object parsed = JSON.deserializeUntyped(req.payloadJson);
                if (!(parsed instanceof Map<String, Object>)) {
                    o.resultJson = JSON.serialize(new Map<String, Object>{'success' => false, 'errorMessage' => 'payloadJson must be a JSON object'});
                    results.add(o);
                    continue;
                }
                Map<String, Object> result = LoanProductConfigService.deployProduct((Map<String, Object>) parsed);
                o.resultJson = JSON.serialize(result);
            } catch (Exception e) {
                String msg = e.getMessage();
                if (String.isBlank(msg)) {
                    msg = e.getTypeName();
                }
                o.resultJson = JSON.serialize(new Map<String, Object>{'success' => false, 'errorMessage' => msg});
            }
            results.add(o);
        }
        return results;
    }
}
