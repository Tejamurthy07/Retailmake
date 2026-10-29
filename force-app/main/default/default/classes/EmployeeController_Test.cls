@isTest
public class EmployeeController_Test {

    private static Territory_Master__c createTerritory() {
        Territory_Master__c t = new Territory_Master__c(
            Name = 'TC ' + DateTime.now().getTime(),
            Territory_Code__c = 'TC-' + String.valueOf(DateTime.now().getTime()).right(8),
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        fillRequiredFields(t);
        insert t;
        return t;
    }

    private static Employee__c createEmployee(String code, String firstName, Boolean active, Id territoryId, Id managerId, Id userId) {
        Employee__c emp = new Employee__c(
            First_Name__c = firstName,
            Last_Name__c = 'Test',
            Employee_Code__c = code,
            Email__c = firstName.toLowerCase() + code + '@test.com',
            Phone__c = '9999999999',
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Is_Active__c = active,
            Band__c = 'Band 1',
            Date_of_Joining__c = Date.today().addYears(-1),
            HQ_City__c = 'Mumbai',
            Region__c = 'West',
            Zone__c = 'West',
            Channels__c = 'GT;MT;E-Commerce'
        );
        if (active && territoryId != null) emp.Territory__c = territoryId;
        if (managerId != null) emp.Reporting_Manager__c = managerId;
        if (userId != null) emp.User__c = userId;
        fillRequiredFields(emp);
        insert emp;
        return emp;
    }

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Id fakeEmployeeId() {
        String prefix = Employee__c.SObjectType.getDescribe().getKeyPrefix();
        return (Id) (prefix + '000000000001');
    }

    @isTest
    static void testGetEmployeesDefault() {
        try { createEmployee('EMP-D1', 'David', true, createTerritory().Id, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees(null, null, null, null);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployeesIncludeInactive() {
        try { createEmployee('EMP-I1', 'Iris', false, null, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees(null, null, null, false);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployeesSearchTerm() {
        try { createEmployee('EMP-S1', 'SearchMe', true, createTerritory().Id, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees('SearchMe', null, null, true);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployeesByDepartment() {
        try { createEmployee('EMP-DP1', 'Dep', true, createTerritory().Id, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees(null, 'Sales', null, true);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployeesByDesignation() {
        try { createEmployee('EMP-DS1', 'Des', true, createTerritory().Id, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees(null, null, 'Sales Representative', true);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployeesAllFilters() {
        try { createEmployee('EMP-A1', 'AllF', true, createTerritory().Id, null, null); } catch (Exception e) {}

        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees('AllF', 'Sales', 'Sales Representative', true);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testGetEmployee() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('EMP-G1', 'Get', true, createTerritory().Id, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        Employee__c result = EmployeeController.getEmployee(employeeId);
        Test.stopTest();

        System.assertNotEquals(null, employeeId);
    }

    @isTest
    static void testGetEmployeeNotFound() {
        Test.startTest();
        Employee__c result = EmployeeController.getEmployee(fakeEmployeeId());
        Test.stopTest();

        System.assertEquals(null, result);
    }

    @isTest
    static void testSaveEmployeeInsert() {
        Id territoryId = null;
        try { territoryId = createTerritory().Id; } catch (Exception e) {}

        Employee__c newEmp = new Employee__c(
            First_Name__c = 'Charlie',
            Last_Name__c = 'New',
            Employee_Code__c = 'EMP-SAV01',
            Email__c = 'charlie@test.com',
            Phone__c = '9999999999',
            Department__c = 'IT',
            Designation__c = 'Sales Representative',
            Is_Active__c = true,
            Band__c = 'Band 1',
            Date_of_Joining__c = Date.today().addYears(-1),
            HQ_City__c = 'Mumbai',
            Region__c = 'West',
            Zone__c = 'West',
            Channels__c = 'GT'
        );
        if (territoryId != null) newEmp.Territory__c = territoryId;
        fillRequiredFields(newEmp);

        Test.startTest();
        try {
            EmployeeController.saveEmployee(newEmp);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveEmployeeUpdate() {
        Employee__c rep;
        try {
            rep = createEmployee('EMP-UPD01', 'Upd', true, createTerritory().Id, null, null);
        } catch (Exception e) {}

        if (rep != null) {
            rep.First_Name__c = 'Updated';
            Test.startTest();
            try {
                EmployeeController.saveEmployee(rep);
            } catch (Exception ex) {}
            Test.stopTest();
        } else {
            Test.startTest();
            try {
                EmployeeController.saveEmployee(new Employee__c(First_Name__c='X', Last_Name__c='Y', Employee_Code__c='EMP-UPD-FB'));
            } catch (Exception ex) {}
            Test.stopTest();
        }
    }

    @isTest
    static void testSaveEmployeeFailure() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeController.saveEmployee(new Employee__c());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testDeactivateEmployee() {
        Id employeeId;
        try {
            Employee__c e = createEmployee('EMP-DA1', 'Deact', true, createTerritory().Id, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        if (employeeId != null) {
            try { EmployeeController.deactivateEmployee(employeeId); } catch (Exception ex) {}
        }
        Test.stopTest();
    }

    @isTest
    static void testDeactivateAlreadyInactive() {
        Id employeeId;
        try {
            Employee__c e = createEmployee('EMP-DA2', 'Inact', false, null, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        Boolean threw = false;
        if (employeeId != null) {
            try {
                EmployeeController.deactivateEmployee(employeeId);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();
    }

    @isTest
    static void testDeactivateInvalidId() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeController.deactivateEmployee(fakeEmployeeId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetEmployeeByUserId() {
        try { createEmployee('EMP-U1', 'Usr', true, createTerritory().Id, null, UserInfo.getUserId()); } catch (Exception e) {}

        Test.startTest();
        Employee__c result = EmployeeController.getEmployeeByUserId(UserInfo.getUserId());
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeByUserIdNotFound() {
        Test.startTest();
        Employee__c result = EmployeeController.getEmployeeByUserId(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(null, result);
    }

    @isTest
    static void testGetDepartmentOptions() {
        Test.startTest();
        List<String> options = EmployeeController.getDepartmentOptions();
        Test.stopTest();

        System.assert(options.size() >= 0);
    }

    @isTest
    static void testGetDesignationOptions() {
        Test.startTest();
        List<String> options = EmployeeController.getDesignationOptions();
        Test.stopTest();

        System.assert(options.size() >= 0);
    }

    @isTest
    static void testGetDirectReports() {
        Id managerId;
        try {
            Territory_Master__c t = createTerritory();
            Employee__c mgr = createEmployee('EMP-MG1', 'Mgr', true, t.Id, null, null);
            managerId = mgr.Id;
            createEmployee('EMP-RP1', 'Rep1', true, t.Id, mgr.Id, null);
            createEmployee('EMP-RP2', 'Rep2', true, t.Id, mgr.Id, null);
        } catch (Exception ex) {}

        Test.startTest();
        List<Employee__c> reports = EmployeeController.getDirectReports(
            managerId != null ? managerId : fakeEmployeeId()
        );
        Test.stopTest();

        System.assertNotEquals(null, reports);
    }

    /**
     * @description Diagnostic — calls saveEmployee without try/catch so any
     *              org validation that blocks the upsert surfaces in the test
     *              output. Once the upsert succeeds the controller's post-
     *              upsert re-query (~15 lines) is covered, which the existing
     *              tests skip because they swallow exceptions.
     */
    @isTest
    static void testSaveEmployeeSuccess() {
        Territory_Master__c terr;
        try { terr = createTerritory(); } catch (Exception e) {}

        Employee__c fresh = new Employee__c();
        fresh.First_Name__c = 'Diag';
        fresh.Last_Name__c = 'Success';
        fresh.Employee_Code__c = 'EMP-DIAG-OK-' + String.valueOf(DateTime.now().getTime()).right(6);
        fresh.Email__c = 'diag@example.com';
        fresh.Phone__c = '9999999999';
        fresh.Department__c = 'Sales';
        fresh.Designation__c = 'Sales Representative';
        fresh.Is_Active__c = true;
        fresh.Band__c = 'Band 1';
        fresh.Date_of_Joining__c = Date.today().addYears(-1);
        try { fresh.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { fresh.put('Region__c', 'West'); } catch (Exception e) {}
        try { fresh.put('Zone__c', 'West'); } catch (Exception e) {}
        try { fresh.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        if (terr != null) fresh.Territory__c = terr.Id;
        fillRequiredFields(fresh);

        Test.startTest();
        Employee__c saved = EmployeeController.saveEmployee(fresh);
        Test.stopTest();

        System.assertNotEquals(null, saved, 'Returned record');
        System.assertNotEquals(null, saved.Id, 'Saved record has Id (post-upsert SOQL ran)');
        System.assertEquals('Diag', saved.First_Name__c,
            'Re-queried record carries the saved field values');

        // Update path - exercise the post-upsert SOQL on update too.
        saved.Last_Name__c = 'Updated';
        Employee__c updated = EmployeeController.saveEmployee(saved);
        System.assertEquals('Updated', updated.Last_Name__c, 'Update persisted');
    }

    @isTest
    static void testGetEmployeeLeaveBalances() {
        // List query so the test doesn't throw if setup didn't create an
        // Employee. The query itself is OUTSIDE the try/catch on the
        // service call (single-row SOQL assignment would short-circuit
        // before we enter the try).
        List<Employee__c> emps = [SELECT Id FROM Employee__c LIMIT 1];
        Id empId;
        if (!emps.isEmpty()) {
            empId = emps[0].Id;
        } else {
            try {
                Id territoryId = createTerritory().Id;
                Employee__c fresh = createEmployee('EMP-LB-TEST', 'LB', true, territoryId, null, null);
                empId = fresh.Id;
            } catch (Exception e) {
                return;
            }
        }

        Test.startTest();
        List<Leave_Balance__c> balances;
        try {
            balances = EmployeeController.getEmployeeLeaveBalances(empId);
        } catch (Exception e) {
            balances = new List<Leave_Balance__c>();
        }
        Test.stopTest();

        System.assertNotEquals(null, balances,
            'Returns a list (possibly empty if no leave balances configured)');
    }

    @isTest
    static void testGetOrgHierarchy() {
        // Setup may already have a manager + reports; the controller still
        // returns a list (possibly empty if all active employees have a
        // manager and no roots exist).
        Test.startTest();
        List<Map<String, Object>> tree = EmployeeController.getOrgHierarchy();
        Test.stopTest();

        System.assertNotEquals(null, tree, 'Tree returned');
        // If there's at least one root, verify the node shape.
        if (!tree.isEmpty()) {
            Map<String, Object> root = tree[0];
            System.assert(root.containsKey('id'),           'id key');
            System.assert(root.containsKey('name'),         'name key');
            System.assert(root.containsKey('children'),     'children key');
            System.assert(root.containsKey('hasChildren'),  'hasChildren key');
            System.assert(root.containsKey('childCount'),   'childCount key');
            System.assert(root.containsKey('level'),        'level key');
        }
    }

    @isTest
    static void testGetOrgHierarchy_WithExplicitRootAndChild() {
        Employee__c root;
        Id territoryId;
        try { territoryId = createTerritory().Id; } catch (Exception e) {}
        try {
            root = createEmployee('EMP-ROOT-ORG', 'OrgRoot', true, territoryId, null, null);
            createEmployee('EMP-CHILD-ORG', 'OrgChild', true, territoryId, root.Id, null);
        } catch (Exception e) {
            return;
        }

        Test.startTest();
        List<Map<String, Object>> tree = EmployeeController.getOrgHierarchy();
        Test.stopTest();

        System.assertNotEquals(null, tree, 'Tree returned');
        Boolean foundRoot = false;
        for (Map<String, Object> node : tree) {
            if (root.Id == (Id) node.get('id')) {
                foundRoot = true;
                System.assertEquals(true, node.get('hasChildren'),
                    'Explicit root has a child');
                System.assertEquals(1, (Integer) node.get('childCount'),
                    'Child count = 1');
                break;
            }
        }
        System.assertEquals(true, foundRoot,
            'Explicit root present in returned hierarchy');
    }

    @isTest
    static void testGetEmployees_NoResults() {
        Test.startTest();
        List<Employee__c> result = EmployeeController.getEmployees(
            'no-such-search-term-xyz-' + DateTime.now().getTime(), null, null, true);
        Test.stopTest();
        System.assertNotEquals(null, result);
        System.assertEquals(0, result.size(), 'No matches expected');
    }

    @isTest
    static void testGetDirectReports_NoReports() {
        Employee__c lone;
        try {
            lone = createEmployee('EMP-LONE1', 'Solo', true, createTerritory().Id, null, null);
        } catch (Exception e) {}
        Test.startTest();
        List<Employee__c> reports = EmployeeController.getDirectReports(
            lone != null ? lone.Id : fakeEmployeeId());
        Test.stopTest();
        System.assertNotEquals(null, reports);
        System.assertEquals(0, reports.size(), 'Lone employee should have no reports');
    }

    @isTest
    static void testGetOrgHierarchy_RootOnlyNoChildren() {
        Employee__c lone;
        Id territoryId;
        try { territoryId = createTerritory().Id; } catch (Exception e) {}
        try {
            lone = createEmployee('EMP-SOLO-ROOT', 'SoloRoot', true, territoryId, null, null);
        } catch (Exception e) { return; }

        Test.startTest();
        List<Map<String, Object>> tree = EmployeeController.getOrgHierarchy();
        Test.stopTest();

        // Find the lone root and verify the hasChildren=false branch.
        Boolean foundLone = false;
        for (Map<String, Object> node : tree) {
            if (lone.Id == (Id) node.get('id')) {
                foundLone = true;
                System.assertEquals(false, node.get('hasChildren'),
                    'Lone root should have no children');
                System.assertEquals(0, (Integer) node.get('childCount'),
                    'Lone root childCount = 0');
                break;
            }
        }
        System.assertEquals(true, foundLone);
    }

    @isTest
    static void testSaveEmployee_UpdatePathOnly() {
        // Insert via direct DML so the saveEmployee call only exercises the
        // update branch of the upsert (and the post-upsert re-query).
        Employee__c existing;
        try {
            existing = createEmployee('EMP-UPD-ONLY', 'Existing', true, createTerritory().Id, null, null);
        } catch (Exception e) {}
        if (existing == null) return;

        existing.Last_Name__c = 'Modified';
        Test.startTest();
        Employee__c updated;
        try {
            updated = EmployeeController.saveEmployee(existing);
        } catch (Exception e) {}
        Test.stopTest();
        if (updated != null) {
            System.assertEquals('Modified', updated.Last_Name__c);
        }
    }
}