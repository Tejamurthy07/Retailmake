@IsTest
private class UOMConversionControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create UOMs
        UOM__c piece = new UOM__c(
            Name = 'Piece', UOM_Code__c = 'PCS', UOM_Type__c = 'Count',
            Is_Base_Unit__c = true, Is_Active__c = true
        );
        UOM__c box = new UOM__c(
            Name = 'Box', UOM_Code__c = 'BOX', UOM_Type__c = 'Packaging',
            Is_Base_Unit__c = false, Is_Active__c = true
        );
        UOM__c caseUom = new UOM__c(
            Name = 'Case', UOM_Code__c = 'CS', UOM_Type__c = 'Packaging',
            Is_Base_Unit__c = false, Is_Active__c = true
        );
        UOM__c inactive = new UOM__c(
            Name = 'Inactive Unit', UOM_Code__c = 'INA', UOM_Type__c = 'Count',
            Is_Base_Unit__c = false, Is_Active__c = false
        );
        insert new List<UOM__c>{ piece, box, caseUom, inactive };

        // Create a product
        Product_Extension__c product = new Product_Extension__c(
            Name = 'Test Product', SKU_Code__c = 'TP001',
            Base_UOM__c = piece.Id, Secondary_UOM__c = box.Id
        );
        insert product;

        // Create global conversion: 1 Box = 12 Pieces
        UOM_Conversion__c globalConv = new UOM_Conversion__c(
            From_UOM__c = box.Id, To_UOM__c = piece.Id,
            Conversion_Factor__c = 12, Is_Active__c = true
        );
        insert globalConv;

        // Create product-specific conversion: 1 Case = 24 Pieces for this product
        UOM_Conversion__c productConv = new UOM_Conversion__c(
            From_UOM__c = caseUom.Id, To_UOM__c = piece.Id,
            Conversion_Factor__c = 24, Product__c = product.Id, Is_Active__c = true
        );
        insert productConv;
    }

    @IsTest
    static void testGetActiveUOMs() {
        List<UOM__c> uoms = UOMConversionController.getActiveUOMs();
        System.assertEquals(3, uoms.size(), 'Should return 3 active UOMs');
    }

    @IsTest
    static void testGetAllUOMs() {
        List<UOM__c> uoms = UOMConversionController.getAllUOMs();
        System.assertEquals(4, uoms.size(), 'Should return all 4 UOMs including inactive');
    }

    @IsTest
    static void testGetConversionsWithProduct() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        List<UOM_Conversion__c> conversions = UOMConversionController.getConversions(product.Id);
        System.assertEquals(2, conversions.size(), 'Should return global + product-specific conversions');
    }

    @IsTest
    static void testGetConversionsGlobalOnly() {
        List<UOM_Conversion__c> conversions = UOMConversionController.getConversions(null);
        System.assertEquals(1, conversions.size(), 'Should return only global conversions');
    }

    @IsTest
    static void testConvertQuantityDirect() {
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];

        Decimal result = UOMConversionController.convertQuantity(5, box.Id, piece.Id, null);
        System.assertEquals(60, result, '5 boxes should be 60 pieces');
    }

    @IsTest
    static void testConvertQuantityReverse() {
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];

        Decimal result = UOMConversionController.convertQuantity(24, piece.Id, box.Id, null);
        System.assertEquals(2, result, '24 pieces should be 2 boxes');
    }

    @IsTest
    static void testConvertQuantitySameUOM() {
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];
        Decimal result = UOMConversionController.convertQuantity(10, piece.Id, piece.Id, null);
        System.assertEquals(10, result, 'Same UOM should return same quantity');
    }

    @IsTest
    static void testConvertQuantityZero() {
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];

        Decimal result = UOMConversionController.convertQuantity(0, box.Id, piece.Id, null);
        System.assertEquals(0, result, 'Zero quantity should return 0');
    }

    @IsTest
    static void testConvertQuantityProductSpecific() {
        UOM__c caseUom = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'CS'];
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Decimal result = UOMConversionController.convertQuantity(2, caseUom.Id, piece.Id, product.Id);
        System.assertEquals(48, result, '2 cases should be 48 pieces for this product');
    }

    @IsTest
    static void testConvertQuantityNoConversionFound() {
        UOM__c caseUom = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'CS'];
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];

        try {
            UOMConversionController.convertQuantity(1, caseUom.Id, box.Id, null);
            System.assert(false, 'Should have thrown an exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('No conversion rule found') ||
                          e.getMessage().contains('Script-thrown exception'),
                          'Should throw no conversion found error');
        }
    }

    @IsTest
    static void testSaveUOMInsert() {
        UOM__c newUom = new UOM__c(
            Name = 'Gram', UOM_Code__c = 'GRM', UOM_Type__c = 'Weight',
            Is_Active__c = true
        );
        UOM__c saved = UOMConversionController.saveUOM(newUom);
        System.assertNotEquals(null, saved.Id, 'UOM should be saved');
        System.assertEquals('GRM', saved.UOM_Code__c);
    }

    @IsTest
    static void testSaveUOMUpdate() {
        UOM__c existing = [SELECT Id, Name, Description__c FROM UOM__c WHERE UOM_Code__c = 'PCS'];
        existing.Description__c = 'Updated description';
        UOM__c saved = UOMConversionController.saveUOM(existing);
        System.assertEquals('Updated description', saved.Description__c);
    }

    @IsTest
    static void testSaveConversion() {
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];
        UOM__c caseUom = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'CS'];

        UOM_Conversion__c newConv = new UOM_Conversion__c(
            From_UOM__c = caseUom.Id, To_UOM__c = box.Id,
            Conversion_Factor__c = 2, Is_Active__c = true
        );
        UOM_Conversion__c saved = UOMConversionController.saveConversionInternal(newConv);
        System.assertNotEquals(null, saved.Id);
        System.assertEquals(0.5000, saved.Inverse_Conversion_Factor__c.setScale(4));
    }

    @IsTest
    static void testSaveConversionSameUOM() {
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];

        UOM_Conversion__c newConv = new UOM_Conversion__c(
            From_UOM__c = piece.Id, To_UOM__c = piece.Id,
            Conversion_Factor__c = 1, Is_Active__c = true
        );
        try {
            UOMConversionController.saveConversionInternal(newConv);
            System.assert(false, 'Should have thrown an exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void testSaveConversionInvalidFactor() {
        UOM__c box = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'BOX'];
        UOM__c piece = [SELECT Id FROM UOM__c WHERE UOM_Code__c = 'PCS'];

        UOM_Conversion__c newConv = new UOM_Conversion__c(
            From_UOM__c = box.Id, To_UOM__c = piece.Id,
            Conversion_Factor__c = -5, Is_Active__c = true
        );
        try {
            UOMConversionController.saveConversionInternal(newConv);
            System.assert(false, 'Should have thrown an exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void testDeleteConversion() {
        UOM_Conversion__c conv = [SELECT Id FROM UOM_Conversion__c WHERE Product__c = null LIMIT 1];
        UOMConversionController.deleteConversion(conv.Id);
        List<UOM_Conversion__c> remaining = [SELECT Id FROM UOM_Conversion__c WHERE Id = :conv.Id];
        System.assertEquals(0, remaining.size(), 'Conversion should be deleted');
    }

    @IsTest
    static void testGetProductConversions() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        List<Map<String, Object>> conversions = UOMConversionController.getProductConversions(product.Id);
        System.assertEquals(2, conversions.size(), 'Should return global + product-specific conversions');

        // Verify structure
        Map<String, Object> first = conversions[0];
        System.assertNotEquals(null, first.get('fromUOMName'));
        System.assertNotEquals(null, first.get('factor'));
    }
}