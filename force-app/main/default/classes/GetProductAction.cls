/**
 * MCP tool: get_product.
 *
 * Wraps `LoanProductConfigService.buildProductGraph(productId)`. Returns the
 * entire product graph as a JSON-stringified payload. Input/Output are inner
 * classes — see ListProductsAction header for the empirical confirmation.
 */
global with sharing class GetProductAction {

    global class Input {
        @InvocableVariable(
            label='Product Id'
            description='Salesforce Id (15- or 18-char) of the Loan_Product__c record to fetch. Use list_products to discover available Ids.'
            required=true
        )
        global String productId;
    }

    global class Output {
        @InvocableVariable(
            label='Product Graph JSON'
            description='Full configuration graph: { loanProduct, relatedObjects, children, fees }. Parse with JSON.deserializeUntyped to navigate. May exceed 100KB for products with many related records.'
        )
        global String graphJson;
    }

    @InvocableMethod(
        label='Get Loan Product'
        description='Fetch the full configuration graph for a single loan product including all related objects (Fee_Set__c, Delinquency_Set__c, Floating_Rate_Index__c, MF_Account__c, etc.) with their nested children, every child relationship (accounting setup, provisioning, commission hierarchy), and a top-level fees map for Fee__c lookups. Call this after list_products to inspect a specific product in detail.'
        callout=false
    )
    global static List<Output> run(List<Input> requests) {
        List<Output> results = new List<Output>();
        for (Input req : requests) {
            Output o = new Output();
            if (String.isBlank(req.productId)) {
                o.graphJson = JSON.serialize(new Map<String, Object>{'success' => false, 'errorMessage' => 'productId is required'});
            } else {
                o.graphJson = JSON.serialize(LoanProductConfigService.buildProductGraph(req.productId));
            }
            results.add(o);
        }
        return results;
    }
}
