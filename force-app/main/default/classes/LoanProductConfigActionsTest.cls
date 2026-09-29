@IsTest
private with sharing class LoanProductConfigActionsTest {

    @TestSetup
    static void setupLoanProduct() {
        ConfigManagerTestDataFactory.createLoanProduct(true);
    }

    @IsTest
    static void shouldListProducts_WhenRequestListIsEmpty() {
        Test.startTest();
        List<ListProductsAction.Output> outputs =
            ListProductsAction.run(new List<ListProductsAction.Input>());
        Test.stopTest();

        Assert.areEqual(1, outputs.size(), 'Empty input should still return one MCP response');
        Map<String, Object> result = deserialize(outputs[0].productsJson);
        Assert.areEqual(ConfigManagerTestDataFactory.hasLoanProductSchema(), result.get('success'),
            'List action should return products or a structured dependency error');
    }

    @IsTest
    static void shouldListProducts_WhenRequestIsProvided() {
        ListProductsAction.Input input = new ListProductsAction.Input();
        input.statusFilter = 'Active';

        Test.startTest();
        List<ListProductsAction.Output> outputs =
            ListProductsAction.run(new List<ListProductsAction.Input>{input});
        Test.stopTest();

        Assert.areEqual(1, outputs.size(), 'Action should return one response per input');
        Assert.areEqual(
            ConfigManagerTestDataFactory.hasLoanProductSchema(),
            deserialize(outputs[0].productsJson).get('success'),
            'A provided request should return products or a structured dependency error'
        );
    }

    @IsTest
    static void shouldGetProductAndValidateBlankInput() {
        Boolean hasLoanSchema = ConfigManagerTestDataFactory.hasLoanProductSchema();
        Id productId;
        if (hasLoanSchema) {
            productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();
        } else {
            Account account = new Account(Name = 'Get Action Without Loan Schema');
            insert account;
            productId = account.Id;
        }
        GetProductAction.Input validInput = new GetProductAction.Input();
        validInput.productId = String.valueOf(productId);
        GetProductAction.Input blankInput = new GetProductAction.Input();

        Test.startTest();
        List<GetProductAction.Output> outputs = GetProductAction.run(
            new List<GetProductAction.Input>{ validInput, blankInput }
        );
        Test.stopTest();

        Assert.areEqual(2, outputs.size(), 'Action should return one response per input');
        Assert.areEqual(hasLoanSchema, deserialize(outputs[0].graphJson).get('success'),
            'Get action should return a graph or a structured dependency error');
        Assert.areEqual(false, deserialize(outputs[1].graphJson).get('success'),
            'Blank product Id should return a validation error');
    }

    @IsTest
    static void shouldDiffProductAndValidateBlankInput() {
        Boolean hasLoanSchema = ConfigManagerTestDataFactory.hasLoanProductSchema();
        Id productId;
        String objectName;
        if (hasLoanSchema) {
            productId = ConfigManagerTestDataFactory.getOnlyLoanProductId();
            objectName = 'Loan_Product__c';
        } else {
            Account account = new Account(Name = 'Diff Action Without Loan Schema');
            insert account;
            productId = account.Id;
            objectName = 'Account';
        }
        DiffRecordAction.Input validInput = new DiffRecordAction.Input();
        validInput.objectName = objectName;
        validInput.recordId = String.valueOf(productId);
        DiffRecordAction.Input blankInput = new DiffRecordAction.Input();

        Test.startTest();
        List<DiffRecordAction.Output> outputs = DiffRecordAction.run(
            new List<DiffRecordAction.Input>{ validInput, blankInput }
        );
        Test.stopTest();

        Assert.areEqual(2, outputs.size(), 'Action should return one response per input');
        Assert.isNotNull(deserialize(outputs[0].diffJson).get('candidates'),
            'Valid diff input should return candidate comparisons');
        Assert.areEqual(false, deserialize(outputs[1].diffJson).get('success'),
            'Blank diff input should return a validation error');
    }

    @IsTest
    static void shouldValidateDeployActionInputs() {
        DeployProductAction.Input blankInput = new DeployProductAction.Input();
        DeployProductAction.Input arrayInput = new DeployProductAction.Input();
        arrayInput.payloadJson = '[]';
        DeployProductAction.Input malformedInput = new DeployProductAction.Input();
        malformedInput.payloadJson = '{not json}';

        Test.startTest();
        List<DeployProductAction.Output> outputs = DeployProductAction.run(
            new List<DeployProductAction.Input>{ blankInput, arrayInput, malformedInput }
        );
        Test.stopTest();

        Assert.areEqual(3, outputs.size(), 'Action should return one response per input');
        for (DeployProductAction.Output output : outputs) {
            Assert.areEqual(false, deserialize(output.resultJson).get('success'),
                'Every invalid deploy input should return a structured error');
        }
    }

    @IsTest
    static void shouldDeployProduct_WhenActionPayloadIsValid() {
        String productName = 'Config Manager MCP Deploy ' + DateTime.now().getTime();
        DeployProductAction.Input input = new DeployProductAction.Input();
        input.payloadJson = JSON.serialize(
            ConfigManagerTestDataFactory.createDeployPayload(productName)
        );

        Test.startTest();
        List<DeployProductAction.Output> outputs = DeployProductAction.run(
            new List<DeployProductAction.Input>{ input }
        );
        Test.stopTest();

        Assert.areEqual(1, outputs.size(), 'Action should return one deploy response');
        Map<String, Object> result = deserialize(outputs[0].resultJson);
        Assert.areEqual(ConfigManagerTestDataFactory.hasLoanProductSchema(), result.get('success'),
            'Deploy should succeed with Loan schema or return a dependency error: ' +
            outputs[0].resultJson);
        if (ConfigManagerTestDataFactory.hasLoanProductSchema()) {
            Assert.isNotNull(result.get('newProductId'),
                'MCP deploy should return the new product Id');
        }
    }

    private static Map<String, Object> deserialize(String payload) {
        return (Map<String, Object>) JSON.deserializeUntyped(payload);
    }
}
