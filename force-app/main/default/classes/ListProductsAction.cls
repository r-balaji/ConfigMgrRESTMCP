/**
 * MCP tool: list_products.
 *
 * Wraps `LoanProductConfigService.listProducts()`. Input/Output declared as
 * inner classes — Salesforce MCP framework's schema discovery resolves them
 * fine (we proved this empirically by deploying 4 classes and re-registering
 * the tools; tools/call returned a full payload). The earlier handoff note
 * claiming inner classes broke discovery was a misdiagnosis — the real bug
 * was the wrong `tools/call` argument shape (must wrap in `inputs: [...]`).
 */
global with sharing class ListProductsAction {

    global class Input {
        @InvocableVariable(
            label='Status Filter'
            description='Optional. Filter products by Status__c (e.g. "Active"). Omit or pass "" to return all products.'
            required=false
        )
        global String statusFilter;
    }

    global class Output {
        @InvocableVariable(
            label='Products JSON'
            description='JSON array of loan products. Each row carries Id, Name, Loan_Product_Type__c, Status__c. Parse with JSON.deserializeUntyped to access fields.'
        )
        global String productsJson;
    }

    @InvocableMethod(
        label='List Loan Products'
        description='Returns every Loan_Product__c in the connected Salesforce org as a lightweight list (Id, Name, Product Type, Status). Use this to discover product Ids before calling get_product.'
        callout=false
    )
    global static List<Output> run(List<Input> requests) {
        List<Output> results = new List<Output>();
        for (Integer i = 0; i < requests.size(); i++) {
            Output o = new Output();
            o.productsJson = JSON.serialize(LoanProductConfigService.listProducts());
            results.add(o);
        }
        if (results.isEmpty()) {
            Output o = new Output();
            o.productsJson = JSON.serialize(LoanProductConfigService.listProducts());
            results.add(o);
        }
        return results;
    }
}
