@IsTest
private with sharing class LoanProductConfigServiceTest {

    @TestSetup
    static void setupLoanProduct() {
        ConfigManagerTestDataFactory.createLoanProduct(true);
    }

    @IsTest
    static void shouldListAndExtractProduct_WhenProductExists() {
        if (!ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            Account account = new Account(Name = 'No Loan Schema');
            insert account;

            Test.startTest();
            Map<String, Object> missingListResult =
                LoanProductConfigService.listProducts();
            Map<String, Object> missingGraphResult =
                LoanProductConfigService.buildProductGraph(String.valueOf(account.Id));
            LoanProductConfigService.loanProductObjectOverride = 'Account';
            Map<String, Object> listResult = LoanProductConfigService.listProducts();
            Map<String, Object> graphResult =
                LoanProductConfigService.buildProductGraph(String.valueOf(account.Id));
            Test.stopTest();

            Assert.areEqual(false, missingListResult.get('success'),
                'List should return a structured dependency error');
            Assert.areEqual(false, missingGraphResult.get('success'),
                'Get should return a structured dependency error');
            Assert.areEqual(true, listResult.get('success'),
                'The dynamic list pipeline should work with a standard test object');
            Assert.areEqual(true, graphResult.get('success'),
                'The dynamic graph pipeline should work with a standard test object');
            Assert.areEqual(
                String.valueOf(account.Id),
                String.valueOf(
                    ((Map<String, Object>) graphResult.get('loanProduct')).get('Id')
                ),
                'The graph should represent the requested standard test record'
            );
            return;
        }
        Id productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();

        Test.startTest();
        Map<String, Object> listResult = LoanProductConfigService.listProducts();
        Map<String, Object> graphResult =
            LoanProductConfigService.buildProductGraph(String.valueOf(productId));
        Test.stopTest();

        Assert.areEqual(true, listResult.get('success'), 'Product list should succeed');
        Assert.isTrue(
            ((Integer) listResult.get('totalProducts')) >= 1,
            'Product list should include the test product'
        );
        Assert.areEqual(true, graphResult.get('success'), 'Product extraction should succeed');
        Map<String, Object> product = (Map<String, Object>) graphResult.get('loanProduct');
        Assert.areEqual(String.valueOf(productId), String.valueOf(product.get('Id')),
            'Extracted graph should represent the requested product');
        Assert.isNotNull(graphResult.get('relatedObjects'), 'Graph should include related objects');
        Assert.isNotNull(graphResult.get('children'), 'Graph should include child configuration');
        Assert.isNotNull(graphResult.get('fees'), 'Graph should include the fees map');
    }

    @IsTest
    static void shouldReturnDiagnostics_WhenRecordIsValid() {
        if (!ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            Account account = new Account(Name = 'Diagnostic Without Loan Schema');
            insert account;

            Test.startTest();
            Map<String, Object> debugResult =
                LoanProductConfigService.debugProduct(String.valueOf(account.Id));
            Map<String, Object> diffResult = LoanProductConfigService.diffRecord(
                'Account', String.valueOf(account.Id)
            );
            LoanProductConfigService.loanProductObjectOverride = 'Account';
            Map<String, Object> substitutedDebugResult =
                LoanProductConfigService.debugProduct(String.valueOf(account.Id));
            Test.stopTest();

            Assert.isNotNull(debugResult.get('queryError'),
                'Missing Loan schema should be diagnosed without throwing');
            Assert.isNotNull(diffResult.get('candidates'),
                'Generic dynamic diff should continue to work');
            Assert.isNotNull(substitutedDebugResult.get('populatedFieldsAsMap'),
                'The dynamic debug query should work with a standard test object');
            return;
        }
        Id productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();

        Test.startTest();
        Map<String, Object> debugResult =
            LoanProductConfigService.debugProduct(String.valueOf(productId));
        Map<String, Object> diffResult = LoanProductConfigService.diffRecord(
            'Loan_Product__c',
            String.valueOf(productId)
        );
        Test.stopTest();

        Assert.areEqual(String.valueOf(productId), debugResult.get('requestedId'),
            'Debug response should echo the requested Id');
        Assert.isNull(debugResult.get('queryError'), 'Debug query should complete successfully');
        Assert.isNotNull(debugResult.get('populatedFieldsAsMap'),
            'Debug response should include populated fields');
        Assert.isNull(diffResult.get('error'), 'Diff should complete successfully');
        List<Object> candidates = (List<Object>) diffResult.get('candidates');
        Assert.isFalse(candidates.isEmpty(), 'Diff should find the source record as a candidate');
    }

    @IsTest
    static void shouldReturnDiagnosticErrors_WhenIdsDoNotMatchTheRequestedObject() {
        if (!ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            Account account = new Account(Name = 'Missing Loan Schema Routes');
            insert account;

            Test.startTest();
            Map<String, Object> invalidDebug = LoanProductConfigService.debugProduct('not-an-id');
            Map<String, Object> unknownDiff = LoanProductConfigService.diffRecord(
                'Loan_Product__c', String.valueOf(account.Id)
            );
            Map<String, Object> graphResult =
                LoanProductConfigService.buildProductGraph(String.valueOf(account.Id));
            RestResponse productResponse = invokeGet(
                '/services/apexrest/v1/loanproductconfig/product/' + account.Id
            );
            Test.stopTest();

            Assert.isNotNull(invalidDebug.get('queryError'), 'Invalid debug Id should be reported');
            Assert.areEqual('Unknown object', unknownDiff.get('error'),
                'Missing Loan object should be reported');
            Assert.areEqual(false, graphResult.get('success'),
                'Direct get should return a structured dependency error');
            Assert.areEqual(false, parseResponse(productResponse).get('success'),
                'REST get should return a structured dependency error');
            return;
        }
        Id productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();
        Account account = new Account(Name = 'Wrong Object Id');
        insert account;
        String missingProductId = String.valueOf(productId).substring(0, 3) + '000000000000';

        Test.startTest();
        Map<String, Object> invalidDebug = LoanProductConfigService.debugProduct('not-an-id');
        Map<String, Object> wrongObjectDiff = LoanProductConfigService.diffRecord(
            'Loan_Product__c', String.valueOf(account.Id)
        );
        Map<String, Object> missingGraph =
            LoanProductConfigService.buildProductGraph(missingProductId);
        RestResponse debugResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/debug/' + productId
        );
        RestResponse wrongObjectResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/product/' + account.Id
        );
        RestResponse wrongShapeResponse = invokePost(
            '/services/apexrest/v1/loanproductconfig/deploy',
            '{"loanProduct":"not-an-object"}'
        );
        Test.stopTest();

        Assert.isNotNull(invalidDebug.get('queryError'), 'Invalid debug Id should be reported');
        Assert.isTrue(String.valueOf(wrongObjectDiff.get('error')).startsWith('Query failed:'),
            'An Id for another object should return a query error');
        Assert.areEqual(false, missingGraph.get('success'),
            'A valid but absent product Id should return not found');
        Assert.isNotNull(parseResponse(debugResponse).get('populatedFieldsAsMap'),
            'Debug REST route should return diagnostic fields');
        Assert.areEqual(false, parseResponse(wrongObjectResponse).get('success'),
            'A wrong-object Id should return a structured not-found response');
        Assert.areEqual(500, wrongShapeResponse.statusCode,
            'A structurally invalid deploy payload should be handled by the REST error boundary');
    }

    @IsTest
    static void shouldRejectInvalidServiceInputs() {
        Test.startTest();
        Map<String, Object> invalidGraph =
            LoanProductConfigService.buildProductGraph('not-an-id');
        Map<String, Object> unknownObject =
            LoanProductConfigService.diffRecord('Missing_Object__c', 'not-an-id');
        Map<String, Object> invalidId =
            LoanProductConfigService.diffRecord('Loan_Product__c', 'not-an-id');
        Map<String, Object> emptyPayload = LoanProductConfigService.deployProduct(null);
        Map<String, Object> missingProduct =
            LoanProductConfigService.deployProduct(new Map<String, Object>());
        Map<String, Object> missingFields = LoanProductConfigService.deployProduct(
            new Map<String, Object>{'loanProduct' => new Map<String, Object>()}
        );
        Test.stopTest();

        Assert.areEqual(false, invalidGraph.get('success'), 'Invalid Id should be rejected');
        Assert.areEqual('Unknown object', unknownObject.get('error'),
            'Unknown object should be reported');
        Assert.areEqual(
            ConfigManagerTestDataFactory.hasLoanProductSchema() ? 'Invalid id' : 'Unknown object',
            invalidId.get('error'),
            'Invalid Id or missing schema should be reported'
        );
        Assert.areEqual(false, emptyPayload.get('success'), 'Null payload should be rejected');
        Assert.areEqual(false, missingProduct.get('success'),
            'Payload without loanProduct should be rejected');
        Assert.areEqual(false, missingFields.get('success'),
            'Payload without product fields should be rejected');
    }

    @IsTest
    static void shouldDeployMinimalProduct_WhenPayloadIsValid() {
        String productName = 'Config Manager Deployed ' + DateTime.now().getTime();
        Map<String, Object> payload =
            ConfigManagerTestDataFactory.createDeployPayload(productName);

        Test.startTest();
        Map<String, Object> result = LoanProductConfigService.deployProduct(payload);
        Map<String, Object> substitutedResult;
        if (!ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            LoanProductConfigService.loanProductObjectOverride = 'Account';
            substitutedResult = LoanProductConfigService.deployProduct(payload);
        }
        Test.stopTest();

        if (ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            Assert.areEqual(true, result.get('success'),
                'A minimal valid product should deploy: ' + JSON.serialize(result));
            Assert.isNotNull(result.get('newProductId'), 'Deploy should return the new product Id');
            Map<String, Object> summary = (Map<String, Object>) result.get('summary');
            Assert.isNotNull(summary.get('created'), 'Deploy should return created counts');
        } else {
            Assert.areEqual(false, result.get('success'),
                'Deploy should return a structured dependency error');
            Assert.areEqual(true, substitutedResult.get('success'),
                'The dynamic deploy pipeline should work with a standard test object: ' +
                JSON.serialize(substitutedResult));
            Assert.isNotNull(substitutedResult.get('newProductId'),
                'The substituted deploy should return the inserted standard record Id');
        }
    }

    @IsTest
    static void shouldRouteRestGetRequests() {
        Boolean hasLoanSchema = ConfigManagerTestDataFactory.hasLoanProductSchema();
        Account account;
        Id productId;
        String diffObject;
        if (hasLoanSchema) {
            productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();
            diffObject = 'Loan_Product__c';
        } else {
            account = new Account(Name = 'REST Routes Without Loan Schema');
            insert account;
            productId = account.Id;
            diffObject = 'Account';
        }

        RestResponse productListResponse = invokeGet('/services/apexrest/v1/loanproductconfig/products');
        RestResponse productResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/product/' + productId
        );
        RestResponse diffResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/diff/' + diffObject + '/' + productId
        );
        RestResponse badDiffResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/diff/Loan_Product__c'
        );
        RestResponse unknownResponse = invokeGet(
            '/services/apexrest/v1/loanproductconfig/missing'
        );

        Assert.areEqual(hasLoanSchema, parseResponse(productListResponse).get('success'),
            'GET products should return data or a dependency error');
        Assert.areEqual(hasLoanSchema, parseResponse(productResponse).get('success'),
            'GET product should return data or a dependency error');
        Assert.isNotNull(parseResponse(diffResponse).get('candidates'),
            'GET diff should route to diffRecord');
        Assert.areEqual(400, badDiffResponse.statusCode, 'Malformed diff route should return 400');
        Assert.areEqual(404, unknownResponse.statusCode, 'Unknown GET route should return 404');
    }

    @IsTest
    static void shouldValidateRestPostRequests() {
        RestResponse emptyResponse = invokePost(
            '/services/apexrest/v1/loanproductconfig/deploy',
            null
        );
        RestResponse malformedResponse = invokePost(
            '/services/apexrest/v1/loanproductconfig/deploy',
            '{not json}'
        );
        RestResponse missingProductResponse = invokePost(
            '/services/apexrest/v1/loanproductconfig/deploy',
            '{}'
        );
        RestResponse unknownResponse = invokePost(
            '/services/apexrest/v1/loanproductconfig/missing',
            '{}'
        );

        Assert.areEqual(400, emptyResponse.statusCode, 'Empty body should return 400');
        Assert.areEqual(400, malformedResponse.statusCode, 'Malformed JSON should return 400');
        Assert.areEqual(false, parseResponse(missingProductResponse).get('success'),
            'Deploy should return a structured validation error');
        Assert.areEqual(404, unknownResponse.statusCode, 'Unknown POST route should return 404');
    }

    private static RestResponse invokeGet(String uri) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'GET';
        request.requestURI = uri;
        RestContext.request = request;
        RestContext.response = new RestResponse();
        LoanProductConfigService.doGet();
        return RestContext.response;
    }

    private static RestResponse invokePost(String uri, String body) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestURI = uri;
        if (body != null) {
            request.requestBody = Blob.valueOf(body);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        LoanProductConfigService.doPost();
        return RestContext.response;
    }

    private static Map<String, Object> parseResponse(RestResponse response) {
        return (Map<String, Object>) JSON.deserializeUntyped(response.responseBody.toString());
    }
}
