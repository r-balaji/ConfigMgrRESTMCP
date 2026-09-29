@IsTest
private with sharing class LoanProductConfigInternalsTest {

    @IsTest
    static void shouldCreateReuseAndRenameReferenceRecords() {
        String uniqueKey = String.valueOf(DateTime.now().getTime());
        Account existing = new Account(
            Name = 'Reference Existing ' + uniqueKey,
            Industry = 'Technology'
        );
        insert existing;

        Map<String, Object> existingSnapshot = (Map<String, Object>)
            LoanProductConfigService.diffRecord('Account', String.valueOf(existing.Id))
                .get('sourceRecord');
        Map<String, Object> renamedSnapshot = new Map<String, Object>(existingSnapshot);
        Map<String, Object> renamedFields = new Map<String, Object>(
            (Map<String, Object>) existingSnapshot.get('fields')
        );
        renamedFields.put('Industry', 'Banking');
        renamedSnapshot.put('Id', 'source-rename');
        renamedSnapshot.put('fields', renamedFields);

        Map<String, Object> createdSnapshot = new Map<String, Object>{
            'Id' => 'source-create',
            'Name' => 'Reference Created ' + uniqueKey,
            'fields' => new Map<String, Object>{'Industry' => 'Consulting'}
        };

        Map<String, String> idRemap = new Map<String, String>();
        Map<String, Integer> reusedCounts = new Map<String, Integer>();
        Map<String, Integer> createdCounts = new Map<String, Integer>();
        List<Map<String, Object>> renamedRecords = new List<Map<String, Object>>();
        Set<String> insertedParentIds = new Set<String>();

        Test.startTest();
        LoanProductConfigService.processReferenceRecords(
            'Account',
            new List<Map<String, Object>>{
                renamedSnapshot,
                createdSnapshot,
                new Map<String, Object>{'Name' => 'Skipped Without Source Id'}
            },
            idRemap,
            reusedCounts,
            createdCounts,
            renamedRecords,
            insertedParentIds,
            new Map<String, List<Map<String, Object>>>(),
            new Map<String, Map<String, Object>>()
        );
        Test.stopTest();

        Assert.isNotNull(idRemap.get('source-rename'),
            'A conflicting reference should be inserted under a new name');
        Assert.isNotNull(idRemap.get('source-create'), 'A new reference should be inserted');
        Assert.areEqual(2, createdCounts.get('Account'), 'Two references should be created');
        Assert.areEqual(1, renamedRecords.size(), 'One name collision should be reported');
        Assert.areEqual(2, insertedParentIds.size(), 'Both inserted records should be tracked');

        Id matchingId = LoanProductConfigService.pickMatchingCandidate(
            'MF_Account__c',
            new Map<String, Object>{'fields' => new Map<String, Object>()},
            new List<SObject>{new Account(Id = existing.Id)},
            new Map<String, List<Map<String, Object>>>(),
            new Map<String, String>(),
            new Map<String, List<Map<String, Object>>>(),
            new Map<String, Map<String, Object>>()
        );
        Assert.areEqual(existing.Id, matchingId,
            'A candidate with equivalent content should be selected');
    }

    @IsTest
    static void shouldCompareFieldsAndValuesAcrossSerializedTypes() {
        Account parent = new Account(Name = 'Comparison Parent');
        insert parent;
        Account target = new Account(
            Name = 'Comparison Target',
            Industry = 'Technology',
            ParentId = parent.Id,
            NumberOfEmployees = 0
        );

        Map<String, Object> matchingFields = new Map<String, Object>{
            'Industry' => 'Technology',
            'ParentId' => 'source-parent'
        };

        Assert.isTrue(LoanProductConfigService.fieldsEqual(
            matchingFields,
            target,
            new Set<String>{'ParentId'},
            new Map<String, String>{'source-parent' => String.valueOf(parent.Id)}
        ), 'Matching values and remapped lookups should compare equal');
        Assert.isFalse(LoanProductConfigService.fieldsEqual(
            matchingFields,
            target,
            new Set<String>{'ParentId'},
            new Map<String, String>()
        ), 'An unmapped lookup should not compare equal');
        Assert.isFalse(LoanProductConfigService.fieldsEqual(
            new Map<String, Object>{'Industry' => 'Banking'},
            target,
            new Set<String>(),
            new Map<String, String>()
        ), 'Different field values should not compare equal');

        Assert.isTrue(LoanProductConfigService.isAbsent(null), 'Null should be absent');
        Assert.isTrue(LoanProductConfigService.isAbsent('  '), 'Blank text should be absent');
        Assert.isFalse(LoanProductConfigService.isAbsent('value'), 'Text should be present');
        Assert.isTrue(LoanProductConfigService.valuesEqual(null, ''),
            'Null and blank should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(false, null),
            'False and absent should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(null, false),
            'Absent and false should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(Decimal.valueOf('0'), null),
            'Decimal zero and absent should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(null, Decimal.valueOf('0')),
            'Absent and decimal zero should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(0, null),
            'Integer zero and absent should compare equal');
        Assert.isTrue(LoanProductConfigService.valuesEqual(null, 0),
            'Absent and integer zero should compare equal');
        Assert.isFalse(LoanProductConfigService.valuesEqual('value', null),
            'Present and absent values should differ');
        Assert.isTrue(LoanProductConfigService.valuesEqual(1, Decimal.valueOf('1.000')),
            'Equivalent numeric types should compare equal');
        Assert.isFalse(LoanProductConfigService.valuesEqual('abc', 1),
            'A nonnumeric string and a number should differ');
    }

    @IsTest
    static void shouldCompareDirectAndJunctionContainerChildren() {
        Map<String, List<Map<String, Object>>> noRelated =
            new Map<String, List<Map<String, Object>>>();
        Map<String, Map<String, Object>> noFees = new Map<String, Map<String, Object>>();

        Map<String, Object> directSnapshot = new Map<String, Object>{
            'Floating_Rate__c' => new List<Object>{
                new Map<String, Object>{'Id' => 'source-rate'}
            }
        };
        List<Map<String, Object>> directTarget = new List<Map<String, Object>>{
            new Map<String, Object>{'id' => 'target-rate'}
        };
        Assert.isTrue(LoanProductConfigService.containerChildrenEqual(
            'Floating_Rate_Index__c', directSnapshot, directTarget,
            new Map<String, String>{'source-rate' => 'target-rate'}, noRelated, noFees
        ), 'A remapped direct child should match');
        Assert.isFalse(LoanProductConfigService.containerChildrenEqual(
            'Floating_Rate_Index__c', directSnapshot, new List<Map<String, Object>>(),
            new Map<String, String>{'source-rate' => 'target-rate'}, noRelated, noFees
        ), 'Different direct-child counts should not match');

        Map<String, Object> junctionSnapshot = new Map<String, Object>{
            'Fee_Junction__c' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{'Fee__c' => 'source-fee'}
                }
            }
        };
        List<Map<String, Object>> junctionTarget = new List<Map<String, Object>>{
            new Map<String, Object>{'fee__c' => 'target-fee'}
        };
        Assert.isTrue(LoanProductConfigService.containerChildrenEqual(
            'Fee_Set__c', junctionSnapshot, junctionTarget,
            new Map<String, String>{'source-fee' => 'target-fee'}, noRelated, noFees
        ), 'A remapped junction child should match');
        Assert.isFalse(LoanProductConfigService.containerChildrenEqual(
            'Fee_Set__c', junctionSnapshot, junctionTarget,
            new Map<String, String>(), noRelated, noFees
        ), 'An unmapped junction child should not match');

        Account candidate = new Account(Name = 'Container Candidate');
        insert candidate;
        Map<String, List<Map<String, Object>>> indexedChildren =
            new Map<String, List<Map<String, Object>>>{
                String.valueOf(candidate.Id) => directTarget
            };
        Id selectedId = LoanProductConfigService.pickMatchingCandidate(
            'Floating_Rate_Index__c',
            new Map<String, Object>{
                'fields' => new Map<String, Object>(),
                'Floating_Rate__c' => directSnapshot.get('Floating_Rate__c')
            },
            new List<SObject>{new Account(Id = candidate.Id)},
            indexedChildren,
            new Map<String, String>{'source-rate' => 'target-rate'},
            noRelated,
            noFees
        );
        Assert.areEqual(candidate.Id, selectedId,
            'A container candidate with equivalent children should be selected');
    }

    @IsTest
    static void shouldBuildSObjectsAndNormalizeJsonPayloads() {
        Account parent = new Account(Name = 'Build Parent');
        insert parent;

        SObject built = LoanProductConfigService.buildSObject(
            'Account',
            new Map<String, Object>{
                'Id' => parent.Id,
                'Name' => 'Built Account',
                'Industry' => 'Technology',
                'ParentId' => 'source-parent',
                'Description' => ' ',
                'Unknown__c' => 'ignored',
                'Phone' => null
            },
            new Map<String, String>{'source-parent' => String.valueOf(parent.Id)},
            new Set<String>{'ParentId'}
        );
        Assert.areEqual('Built Account', built.get('Name'), 'Createable fields should be copied');
        Assert.areEqual(parent.Id, built.get('ParentId'), 'Lookup Id should be remapped');
        Assert.isNull(built.get('Description'), 'Blank values should be skipped');

        SObject withoutLookup = LoanProductConfigService.buildSObject(
            'Account',
            new Map<String, Object>{'Name' => 'No Parent', 'ParentId' => 'unmapped'},
            new Map<String, String>(),
            new Set<String>{'ParentId'}
        );
        Assert.isNull(withoutLookup.get('ParentId'), 'Unmapped lookups should be omitted');

        try {
            LoanProductConfigService.buildSObject(
                'Missing_Object__c', new Map<String, Object>(),
                new Map<String, String>(), new Set<String>()
            );
            Assert.fail('Unknown objects should throw DeployException');
        } catch (LoanProductConfigService.DeployException expected) {
            Assert.isTrue(expected.getMessage().contains('Unknown object'),
                'Exception should identify the missing object');
        }

        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
            '{"records":[{"Name":"One"},7],"invalid":"text",' +
            '"maps":{"first":{"Name":"One"},"skip":[1]}}'
        );
        Map<String, List<Map<String, Object>>> normalizedLists =
            LoanProductConfigService.normalizeListOfMapMap(raw);
        Map<String, Map<String, Object>> normalizedMaps =
            LoanProductConfigService.normalizeMapOfMap((Map<String, Object>) raw.get('maps'));

        Assert.areEqual(1, normalizedLists.get('records').size(),
            'Only map entries should remain in normalized lists');
        Assert.isFalse(normalizedLists.containsKey('invalid'),
            'Non-list values should be skipped');
        Assert.areEqual(1, normalizedMaps.size(), 'Only map values should be retained');
    }

    @IsTest
    static void shouldCollectNestedReferencesAndFindNextSuffix() {
        Map<String, Object> fee = new Map<String, Object>{'Id' => 'fee-source'};
        Map<String, Map<String, Object>> fees =
            new Map<String, Map<String, Object>>{'fee-source' => fee};
        Map<String, Object> rate = new Map<String, Object>{'Id' => 'rate-source'};
        Map<String, List<Map<String, Object>>> related =
            new Map<String, List<Map<String, Object>>>{
                'Floating_Rate_Index__c' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Floating_Rate__c' => new List<Object>{rate}
                    },
                    new Map<String, Object>()
                },
                'Account' => new List<Map<String, Object>>{
                    new Map<String, Object>{'Id' => 'account-source'}
                }
            };

        Assert.areEqual(1,
            LoanProductConfigService.collectReferenceRecords('Fee__c', related, fees).size(),
            'Fees should be collected from the Id-keyed fee map');
        Assert.areEqual(1,
            LoanProductConfigService.collectReferenceRecords(
                'Floating_Rate__c', related, fees
            ).size(),
            'Nested floating rates should be flattened');
        Assert.areEqual(1,
            LoanProductConfigService.collectReferenceRecords('Account', related, fees).size(),
            'Ordinary related records should be returned directly');
        Assert.isNull(
            LoanProductConfigService.collectReferenceRecords(
                'Account', null, new Map<String, Map<String, Object>>()
            ),
            'Missing related data should return null'
        );

        String baseName = 'Suffix ' + DateTime.now().getTime();
        insert new List<Account>{
            new Account(Name = baseName + '-Copy-1'),
            new Account(Name = baseName + '-Copy-3'),
            new Account(Name = baseName + '-Copy-not-a-number')
        };
        Assert.areEqual(baseName + '-Copy-2',
            LoanProductConfigService.nextAvailableSuffixedName('Account', baseName),
            'The first unused numeric suffix should be selected');
    }

    @IsTest
    static void shouldQueryAndMergeGenericParentChildRecords() {
        Account parent = new Account(Name = 'Generic Parent');
        insert parent;
        insert new Contact(LastName = 'Generic Child', AccountId = parent.Id);
        Set<Id> parentIds = new Set<Id>{ parent.Id };

        Test.startTest();
        List<Map<String, Object>> queried =
            LoanProductConfigService.queryByIds('Account', parentIds);
        List<Map<String, Object>> withChildren =
            LoanProductConfigService.fetchParentWithChildren(
                'Account', 'Contact', 'AccountId', parentIds
            );
        Map<String, List<Map<String, Object>>> merged =
            new Map<String, List<Map<String, Object>>>();
        LoanProductConfigService.mergeFetchedRecords(merged, 'Account', parentIds);
        LoanProductConfigService.mergeFetchedRecords(merged, 'Account', parentIds);
        List<Map<String, Object>> emptyQuery =
            LoanProductConfigService.queryByIds('Account', new Set<Id>());
        List<Map<String, Object>> unknownQuery =
            LoanProductConfigService.queryByIds('Missing_Object__c', parentIds);
        Test.stopTest();

        Assert.areEqual(1, queried.size(), 'Generic Id queries should return the parent');
        Assert.areEqual(1, withChildren.size(), 'The generic deep fetch should return the parent');
        Assert.areEqual(
            1,
            ((List<Map<String, Object>>) withChildren[0].get('Contact')).size(),
            'The generic deep fetch should nest matching child records'
        );
        Assert.areEqual(1, merged.get('Account').size(),
            'Repeated merges should not duplicate an existing record');
        Assert.isTrue(emptyQuery.isEmpty(), 'An empty Id set should not query');
        Assert.isTrue(unknownQuery.isEmpty(), 'An unknown object should be ignored');
    }
}
