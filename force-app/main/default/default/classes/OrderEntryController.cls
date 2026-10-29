/**
 * @description Controller for the Order Entry LWC component.
 *              Handles product search, sales order creation with line items,
 *              scheme application, and order history retrieval for FMCG field sales.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class OrderEntryController {

    // Standard search — applies the MDM per-account category (MDM-004) and
    // channel (MDM-003) product restrictions.
    @AuraEnabled(cacheable=true)
    public static List<ProductSearchResult> searchProducts(String searchTerm, String categoryId, String accountId) {
        return searchProductsImpl(searchTerm, categoryId, accountId, false);
    }

    // Browse-all search for the demo order pad — skips the per-account category
    // and channel restrictions (so the full catalog shows regardless of an
    // outlet's MDM mappings) while KEEPING account-specific price resolution.
    @AuraEnabled(cacheable=true)
    public static List<ProductSearchResult> searchProductsAll(String searchTerm, String categoryId, String accountId) {
        return searchProductsImpl(searchTerm, categoryId, accountId, true);
    }

    private static List<ProductSearchResult> searchProductsImpl(String searchTerm, String categoryId, String accountId, Boolean bypassAccountFilters) {
        String query = 'SELECT Id, Name, SKU_Code__c, Is_Active__c, MRP__c, Unit_Price__c, GST_Rate__c, ' +
                       'Unit_of_Measure__c, Base_UOM__c, Base_UOM__r.UOM_Code__c, Base_UOM__r.Name, ' +
                       'Secondary_UOM__c, Secondary_UOM__r.UOM_Code__c, Secondary_UOM__r.Name, ' +
                       'Ordering_UOMs__c, Case_Size__c, Channels__c, Product_Category__c, Product_Image_URL__c ' +
                       'FROM Product_Extension__c WHERE Is_Active__c = true';
        String searchKey;
        if (String.isNotBlank(searchTerm)) {
            searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            query += ' AND (Name LIKE :searchKey OR SKU_Code__c LIKE :searchKey)';
        }
        if (String.isNotBlank(categoryId)) {
            query += ' AND Product_Category__r.Name = :categoryId';
        }

        // MDM-004: Category-based filtering when account has category mappings
        Set<Id> expandedCategoryIds;
        if (!bypassAccountFilters && BPM_FeatureToggle_Util.isEnabled('MDM-004') && String.isNotBlank(accountId)) {
            try {
                Id acctId = Id.valueOf(accountId);
                Set<Id> acctCatIds = MDM_CategoryMapping_Service.getAccountCategoryIds(acctId);
                if (!acctCatIds.isEmpty()) {
                    expandedCategoryIds = MDM_CategoryMapping_Service.expandCategoryHierarchy(acctCatIds);
                    query += ' AND Product_Category__c IN :expandedCategoryIds';
                }
            } catch (StringException e) {
                // invalid accountId — skip category filtering
            }
        }

        query += ' ORDER BY Name LIMIT 50';
        List<Product_Extension__c> products = Database.query(query);

        // MDM-003: Channel-based post-query filtering
        if (!bypassAccountFilters && BPM_FeatureToggle_Util.isEnabled('MDM-003') && String.isNotBlank(accountId)) {
            try {
                Id acctId = Id.valueOf(accountId);
                String acctChannel = MDM_ChannelMapping_Service.resolveTradeChannel(acctId);
                if (String.isNotBlank(acctChannel)) {
                    products = MDM_ChannelMapping_Service.filterProductsByChannel(products, acctChannel);
                }
            } catch (StringException e) {
                // invalid accountId — skip channel filtering
            }
        }

        if (products.isEmpty()) {
            return new List<ProductSearchResult>();
        }

        // Look up account details for priority-based price resolution
        String channel = '';
        Id acctTerritoryId = null;
        Id acctIdResolved = null;
        if (String.isNotBlank(accountId)) {
            try {
                acctIdResolved = Id.valueOf(accountId);
                List<Account> accts = [SELECT Channel__c, Territory__c FROM Account WHERE Id = :acctIdResolved LIMIT 1];
                if (!accts.isEmpty()) {
                    if (String.isNotBlank(accts[0].Channel__c)) {
                        channel = accts[0].Channel__c;
                    }
                    acctTerritoryId = accts[0].Territory__c;
                }
            } catch (StringException e) {
                // accountId is not a valid Salesforce Id — skip account resolution
            }
        }

        // Collect product IDs and category mappings for price resolution
        Set<Id> productIds = new Set<Id>();
        Map<Id, Id> productCategoryMap = new Map<Id, Id>();
        for (Product_Extension__c p : products) {
            productIds.add(p.Id);
        }

        // Fetch product categories for priority-based pricing
        for (Product_Extension__c pe : [
            SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id IN :productIds
        ]) {
            if (pe.Product_Category__c != null) {
                productCategoryMap.put(pe.Id, pe.Product_Category__c);
            }
        }

        // Resolve prices using full priority hierarchy from Price_List__c
        Map<Id, Decimal> resolvedPrices = resolvePricesByPriority(
            productIds, acctIdResolved, acctTerritoryId, channel, productCategoryMap
        );

        // Build results with resolved prices
        List<ProductSearchResult> results = new List<ProductSearchResult>();
        for (Product_Extension__c p : products) {
            ProductSearchResult r = new ProductSearchResult();
            r.Id = p.Id;
            r.Name = p.Name;
            r.SKU_Code = p.SKU_Code__c;
            r.ImageUrl = p.Product_Image_URL__c;
            r.MRP = p.MRP__c;
            r.GST_Rate = p.GST_Rate__c;

            // Use priority-resolved price > product Unit_Price > MRP as fallback
            Decimal resolvedPrice = resolvedPrices.get(p.Id);
            r.Unit_Price = resolvedPrice != null && resolvedPrice > 0
                ? resolvedPrice
                : (p.Unit_Price__c != null ? p.Unit_Price__c : p.MRP__c);
            r.UOM = p.Unit_of_Measure__c != null ? p.Unit_of_Measure__c : 'Piece';
            r.BaseUOMCode = (p.Base_UOM__c != null && p.Base_UOM__r.UOM_Code__c != null)
                ? p.Base_UOM__r.UOM_Code__c : 'PCS';
            r.BaseUOMId = p.Base_UOM__c;
            r.BaseUOMName = (p.Base_UOM__c != null && p.Base_UOM__r.Name != null)
                ? p.Base_UOM__r.Name : 'Piece';
            r.SecondaryUOMCode = (p.Secondary_UOM__c != null && p.Secondary_UOM__r.UOM_Code__c != null)
                ? p.Secondary_UOM__r.UOM_Code__c : null;
            r.SecondaryUOMId = p.Secondary_UOM__c;
            r.SecondaryUOMName = (p.Secondary_UOM__c != null && p.Secondary_UOM__r.Name != null)
                ? p.Secondary_UOM__r.Name : null;
            r.OrderingUOMs = p.Ordering_UOMs__c;
            r.CaseSize = p.Case_Size__c;

            results.add(r);
        }

        return results;
    }

    private static Decimal resolvePrice(Id productId, String region, String channel, Map<String, Price_List__c> priceListMap) {
        // Try product + region + channel
        String key = String.valueOf(productId) + '|' +
                     (String.isNotBlank(region) ? region : '') + '|' +
                     (String.isNotBlank(channel) ? channel : '');
        if (priceListMap.containsKey(key)) {
            return priceListMap.get(key).Unit_Price__c;
        }
        // Try product + region only
        key = String.valueOf(productId) + '|' +
              (String.isNotBlank(region) ? region : '') + '|';
        if (priceListMap.containsKey(key)) {
            return priceListMap.get(key).Unit_Price__c;
        }
        // Try product only (national/default)
        key = String.valueOf(productId) + '||';
        if (priceListMap.containsKey(key)) {
            return priceListMap.get(key).Unit_Price__c;
        }
        return 0;
    }

    /**
     * @description Resolves prices for a set of products using the full 8-level
     *              priority hierarchy from Price_List__c records.
     *              Priority levels (1=highest): Customer > Cat+Terr+Chan > Terr+Chan >
     *              Cat+Terr > Territory > Channel > Category > Base.
     *
     * @param productIds Set of Product_Extension__c Ids to resolve prices for.
     * @param accountId  The customer account Id (for customer-specific pricing).
     * @param territoryId The territory Id from the account.
     * @param channel    The sales channel from the account.
     * @param productCategoryMap Map of productId to category Id.
     * @return Map of productId to resolved unit price.
     */
    private static Map<Id, Decimal> resolvePricesByPriority(
        Set<Id> productIds,
        Id accountId,
        Id territoryId,
        String channel,
        Map<Id, Id> productCategoryMap
    ) {
        Map<Id, Decimal> resolvedPrices = new Map<Id, Decimal>();
        if (productIds == null || productIds.isEmpty()) {
            return resolvedPrices;
        }

        // Fetch active price list entries ordered by priority (ascending = highest priority first)
        List<Price_List__c> priceLists = [
            SELECT Id, Product_Ext__c, Customer__c, Category__c,
                   Territory__c, Channel__c, Priority__c,
                   Unit_Price__c, Min_Qty__c
            FROM Price_List__c
            WHERE Product_Ext__c IN :productIds
              AND Is_Active__c = true
              AND Effective_From__c <= TODAY
              AND (Effective_To__c >= TODAY OR Effective_To__c = null)
            ORDER BY Priority__c ASC, Effective_From__c DESC
        ];

        // Group by product
        Map<Id, List<Price_List__c>> pricesByProduct = new Map<Id, List<Price_List__c>>();
        for (Price_List__c pl : priceLists) {
            if (!pricesByProduct.containsKey(pl.Product_Ext__c)) {
                pricesByProduct.put(pl.Product_Ext__c, new List<Price_List__c>());
            }
            pricesByProduct.get(pl.Product_Ext__c).add(pl);
        }

        // Resolve price for each product using priority-based matching
        for (Id productId : productIds) {
            List<Price_List__c> productPrices = pricesByProduct.get(productId);
            if (productPrices == null || productPrices.isEmpty()) {
                continue;
            }

            Id categoryId = productCategoryMap != null ? productCategoryMap.get(productId) : null;

            for (Price_List__c pl : productPrices) {
                Boolean matches = true;

                // Customer dimension
                if (pl.Customer__c != null) {
                    if (accountId == null || pl.Customer__c != accountId) {
                        matches = false;
                    }
                }
                // Category dimension
                if (matches && pl.Category__c != null) {
                    if (categoryId == null || pl.Category__c != categoryId) {
                        matches = false;
                    }
                }
                // Territory dimension
                if (matches && pl.Territory__c != null) {
                    if (territoryId == null || pl.Territory__c != territoryId) {
                        matches = false;
                    }
                }
                // Channel dimension
                if (matches && String.isNotBlank(pl.Channel__c)) {
                    if (String.isBlank(channel) || pl.Channel__c != channel) {
                        matches = false;
                    }
                }

                if (matches) {
                    resolvedPrices.put(productId, pl.Unit_Price__c);
                    break;
                }
            }
        }

        return resolvedPrices;
    }

    @AuraEnabled
    public static Sales_Order__c createSalesOrder(String orderJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(orderJson);

            // When payload.orderId is present, treat this as an EDIT of an
            // existing Draft order: reuse the same Sales_Order__c record,
            // refresh the header fields, and wipe its Order_Line_Item__c
            // rows so the new line collection is the single source of truth.
            // Only Draft orders are allowed to edit — submitted/approved
            // orders must not be mutated via this path.
            String editOrderId = (String) payload.get('orderId');
            Boolean isEdit = String.isNotBlank(editOrderId);

            Sales_Order__c order;
            if (isEdit) {
                // Pull Visit__c / Account__c so we can preserve them when
                // the payload omits them — prevents the edit flow from
                // silently unlinking a draft from its visit, which makes
                // the order disappear from the Visit Manager's Orders tab.
                List<Sales_Order__c> existing = [
                    SELECT Id, Status__c, Visit__c, Account__c, Beat__c, Territory__c, Day_Attendance__c, Order_Date__c, Salesperson__c FROM Sales_Order__c
                    WHERE Id = :editOrderId LIMIT 1
                ];
                if (existing.isEmpty()) {
                    throw new AuraHandledException('Order not found for edit: ' + editOrderId);
                }
                if (existing[0].Status__c != 'Draft') {
                    throw new AuraHandledException(
                        'Only Draft orders can be edited. Order is currently ' + existing[0].Status__c + '.'
                    );
                }
                order = existing[0];
                // Remove existing lines — fresh insert below using the new payload.
                delete [SELECT Id FROM Order_Line_Item__c WHERE Sales_Order__c = :order.Id];
            } else {
                order = new Sales_Order__c();
                order.Order_Date__c = Date.today();
            }

            // Only overwrite Account/Visit when payload explicitly carries
            // them. In the edit path the existing record already has them;
            // the form may not always re-send (depending on entry path), and
            // wiping them would orphan the order from its visit.
            if (payload.get('accountId') != null) {
                order.Account__c = (String) payload.get('accountId');
            }
            if (payload.get('visitId') != null) {
                order.Visit__c = (String) payload.get('visitId');
            }
            // For the edit flow, defer the status transition until AFTER
            // we've re-inserted the fresh line items. Otherwise the SO
            // beforeUpdate trigger's validateMustSellCompliance (which
            // fires on Draft -> Submitted) sees zero OLIs (we just
            // deleted them) and incorrectly flags every required
            // must-sell product as 'missing'. We keep the record at
            // 'Draft' through the header upsert + OLI re-insert, then
            // flip to the target status in a follow-up update where the
            // validator can see the freshly-inserted lines.
            String targetStatus = (String) payload.get('status');
            if (isEdit && targetStatus != null && targetStatus != 'Draft') {
                order.Status__c = 'Draft';
            } else {
                order.Status__c = targetStatus;
            }
            order.Notes__c = (String) payload.get('remarks');
            order.Total_Gross_Amount__c = toDecimal(payload.get('grossAmount'));
            order.Total_Discount__c = toDecimal(payload.get('totalDiscount'));
            order.Total_Tax__c = toDecimal(payload.get('totalTax'));
            order.Total_Net_Amount__c = toDecimal(payload.get('netAmount'));

            // Resolve Territory via a fallback cascade so the order doesn't
            // trip the Territory_Required_On_Submit validation rule when the
            // outlet hasn't been mapped to a territory directly:
            //   1. Account.Territory__c          (primary)
            //   2. Visit.Beat.Territory__c       (ad-hoc / non-mapped outlet)
            //   3. Current user's Employee.Territory__c (last-resort)
            // Still leaves the field null if none of the above resolve so
            // the validation rule can surface a clear error to the user.
            if (order.Account__c != null) {
                List<Account> accts = [SELECT Territory__c FROM Account WHERE Id = :order.Account__c LIMIT 1];
                if (!accts.isEmpty() && accts[0].Territory__c != null) {
                    order.Territory__c = accts[0].Territory__c;
                }
            }
            // When the order is tied to a visit, copy the visit's Beat and
            // Day_Attendance context onto the order so reporting (visit
            // productivity, beat-wise sales, daily attendance coverage)
            // doesn't have to traverse Visit__r every time. Also backfills
            // Territory from the beat if Account didn't supply one.
            if (order.Visit__c != null) {
                List<Visit__c> visits = [
                    SELECT Beat__c, Beat__r.Territory__c, Day_Attendance__c
                    FROM Visit__c WHERE Id = :order.Visit__c LIMIT 1
                ];
                if (!visits.isEmpty()) {
                    Visit__c v = visits[0];
                    if (v.Beat__c != null && order.Beat__c == null) {
                        order.Beat__c = v.Beat__c;
                    }
                    if (v.Day_Attendance__c != null && order.Day_Attendance__c == null) {
                        order.Day_Attendance__c = v.Day_Attendance__c;
                    }
                    if (order.Territory__c == null
                        && v.Beat__r != null && v.Beat__r.Territory__c != null) {
                        order.Territory__c = v.Beat__r.Territory__c;
                    }
                }
            }
            if (order.Territory__c == null) {
                List<Employee__c> emps = [
                    SELECT Territory__c FROM Employee__c
                    WHERE User__c = :UserInfo.getUserId()
                      AND Territory__c != null
                    LIMIT 1
                ];
                if (!emps.isEmpty()) {
                    order.Territory__c = emps[0].Territory__c;
                }
            }

            // MDM-003: Populate Trade_Channel__c from Account's trade channel
            if (BPM_FeatureToggle_Util.isEnabled('MDM-003') && order.Account__c != null) {
                String tradeChannel = MDM_ChannelMapping_Service.resolveTradeChannel(order.Account__c);
                if (String.isNotBlank(tradeChannel)) {
                    order.Trade_Channel__c = tradeChannel;
                }

                // Validate employee is authorized for this channel
                List<Employee__c> currentEmps = [
                    SELECT Id, Channels__c FROM Employee__c
                    WHERE User__c = :UserInfo.getUserId() AND Is_Active__c = true LIMIT 1
                ];
                if (!currentEmps.isEmpty() && String.isNotBlank(tradeChannel)) {
                    if (!MDM_ChannelMapping_Service.isEmployeeAuthorizedForChannel(currentEmps[0], tradeChannel)) {
                        throw new AuraHandledException('You are not authorized to sell in channel: ' + tradeChannel);
                    }
                }
            }

            // Set warehouse if selected
            if (payload.get('warehouseId') != null) {
                order.Warehouse__c = (String) payload.get('warehouseId');
            }
            if (payload.containsKey('mustSellOverride') && payload.get('mustSellOverride') == true) {
                order.Must_Sell_Override__c = true;
            }
            if (payload.containsKey('mustSellCompliance')) {
                order.Must_Sell_Compliance__c = toDecimal(payload.get('mustSellCompliance'));
            }

            // Credit control (server-authoritative). Only a real submit is
            // checked; drafts never route. When the order value plus the
            // outlet's current outstanding would breach its credit limit, flag
            // the order so the auto-approval flow skips it and it is routed to a
            // human approver below. Credit_Available__c is recorded for context.
            Boolean requiresCreditApproval = false;
            if (targetStatus == 'Submitted' && order.Account__c != null) {
                Decimal orderNet = toDecimal(payload.get('netAmount'));
                if (orderNet == null) orderNet = 0;
                List<Account> creditAccts = [
                    SELECT Credit_Limit__c, Credit_Utilized__c, Outstanding_Balance__c
                    FROM Account WHERE Id = :order.Account__c LIMIT 1
                ];
                if (!creditAccts.isEmpty()) {
                    Decimal limitAmt = creditAccts[0].Credit_Limit__c != null ? creditAccts[0].Credit_Limit__c : 0;
                    // Exposure = greater of the two divergent credit fields.
                    Decimal outstanding = Math.max(
                        creditAccts[0].Credit_Utilized__c != null ? creditAccts[0].Credit_Utilized__c : 0,
                        creditAccts[0].Outstanding_Balance__c != null ? creditAccts[0].Outstanding_Balance__c : 0
                    );
                    order.Credit_Available__c = limitAmt - outstanding;
                    order.Credit_Checked__c = true;
                    if (limitAmt > 0 && (outstanding + orderNet) > limitAmt) {
                        requiresCreditApproval = true;
                    }
                }
            }
            order.Requires_Credit_Approval__c = requiresCreditApproval;

            // Stamp the rep's credit-approval comment onto the order's Notes so
            // it is visible on the order record itself (it is also recorded on
            // the Approval_Request__c via ApprovalRouter.submit below).
            if (requiresCreditApproval) {
                String approvalNote = (String) payload.get('approvalComment');
                if (String.isNotBlank(approvalNote)) {
                    String stamp = 'Credit approval note: ' + approvalNote;
                    order.Notes__c = String.isNotBlank(order.Notes__c)
                        ? order.Notes__c + '\n' + stamp
                        : stamp;
                }
            }

            upsert order;

            List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>();
            List<Object> items = (List<Object>) payload.get('lineItems');
            if (items != null) {
                // Collect product Ids for bulk UOM resolution
                Set<Id> lineProductIds = new Set<Id>();
                for (Object itemObj : items) {
                    Map<String, Object> itm = (Map<String, Object>) itemObj;
                    if (itm.get('productId') != null) {
                        try {
                            lineProductIds.add(Id.valueOf((String) itm.get('productId')));
                        } catch (Exception ex) { /* skip invalid ids */ }
                    }
                }

                // Bulk-fetch product base UOM info
                Map<Id, Product_Extension__c> productUOMMap = new Map<Id, Product_Extension__c>();
                if (!lineProductIds.isEmpty()) {
                    for (Product_Extension__c pe : [
                        SELECT Id, Base_UOM__c, Base_UOM__r.UOM_Code__c
                        FROM Product_Extension__c
                        WHERE Id IN :lineProductIds
                    ]) {
                        productUOMMap.put(pe.Id, pe);
                    }
                }

                // Build conversion requests for bulk conversion
                List<UOM_Conversion_Service.ConversionRequest> convRequests = new List<UOM_Conversion_Service.ConversionRequest>();
                List<Map<String, Object>> itemMaps = new List<Map<String, Object>>();

                for (Object itemObj : items) {
                    Map<String, Object> item = (Map<String, Object>) itemObj;
                    itemMaps.add(item);

                    Id productId = item.get('productId') != null ? Id.valueOf((String) item.get('productId')) : null;
                    String uomCode = item.get('uomCode') != null ? (String) item.get('uomCode') : null;
                    String uomPicklist = item.get('uom') != null ? (String) item.get('uom') : 'Pieces';
                    Decimal qty = toDecimal(item.get('quantity'));

                    // Resolve the order UOM code
                    if (String.isBlank(uomCode)) {
                        uomCode = UOM_Conversion_Service.mapPicklistToCode(uomPicklist);
                    }

                    // Get base UOM code for the product
                    String baseUomCode = 'PCS';
                    if (productId != null && productUOMMap.containsKey(productId)) {
                        Product_Extension__c pe = productUOMMap.get(productId);
                        if (pe.Base_UOM__c != null && String.isNotBlank(pe.Base_UOM__r.UOM_Code__c)) {
                            baseUomCode = pe.Base_UOM__r.UOM_Code__c;
                        }
                    }

                    UOM_Conversion_Service.ConversionRequest cr = new UOM_Conversion_Service.ConversionRequest();
                    cr.productId = productId;
                    cr.fromUomCode = uomCode;
                    cr.toUomCode = baseUomCode;
                    cr.quantity = qty;
                    convRequests.add(cr);
                }

                // Bulk convert
                List<UOM_Conversion_Service.ConvertedResult> convResults = UOM_Conversion_Service.bulkConvert(convRequests);

                // Bulk-fetch product MRP / HSN so we can populate those
                // fields on each Order_Line_Item__c (otherwise they'd stay
                // blank on the created record — they're not in the LWC
                // payload and the trigger pipeline doesn't set them).
                Map<Id, Product_Extension__c> productMetaMap = new Map<Id, Product_Extension__c>();
                if (!lineProductIds.isEmpty()) {
                    for (Product_Extension__c pe : [
                        SELECT Id, MRP__c, HSN_SAC_Code__c, Product_Category__c
                        FROM Product_Extension__c
                        WHERE Id IN :lineProductIds
                    ]) {
                        productMetaMap.put(pe.Id, pe);
                    }
                }

                // Populate the same-transaction hint map the OLI trigger
                // reads, so the UI's Must-Sell 'Min: X' badge is honoured
                // at save time without relying on the trigger's Must-Sell
                // SOQL returning the same record (which has been observed
                // to miss valid configs depending on context).
                OMS_OrderLineItem_TriggerHandler.uiMinQtyByProduct.clear();
                for (Object raw : itemMaps) {
                    Map<String, Object> it = (Map<String, Object>) raw;
                    Object minRaw = it.get('minQuantity');
                    Object pidRaw = it.get('productId');
                    if (minRaw == null || pidRaw == null) continue;
                    Decimal minQty = toDecimal(minRaw);
                    if (minQty != null && minQty > 0) {
                        OMS_OrderLineItem_TriggerHandler.uiMinQtyByProduct.put(
                            (Id) pidRaw, minQty
                        );
                    }
                }

                for (Integer i = 0; i < itemMaps.size(); i++) {
                    Map<String, Object> item = itemMaps[i];
                    UOM_Conversion_Service.ConvertedResult conv = convResults[i];

                    Order_Line_Item__c li = new Order_Line_Item__c();
                    li.Sales_Order__c = order.Id;
                    Id prodId = item.get('productId') != null
                        ? Id.valueOf((String) item.get('productId')) : null;
                    li.Product_Ext__c = prodId;
                    li.Quantity__c = toDecimal(item.get('quantity'));
                    li.Free_Quantity__c = toDecimal(item.get('freeQty'));
                    li.Unit_Price__c = toDecimal(item.get('rate'));
                    // Line_Total__c = gross (qty * rate). Fallback to
                    // calculating it locally when the payload value is
                    // missing or zero so the stored row always has a real
                    // subtotal to display.
                    Decimal payloadGross = toDecimal(item.get('grossAmount'));
                    Decimal liQty = toDecimal(item.get('quantity'));
                    Decimal liRate = toDecimal(item.get('rate'));
                    if (payloadGross == null || payloadGross == 0) {
                        payloadGross = (liQty != null && liRate != null) ? liQty * liRate : 0;
                    }
                    li.Line_Total__c = payloadGross;
                    li.Discount_Amount__c = toDecimal(item.get('discountAmount'));
                    li.Discount_Percent__c = toDecimal(item.get('discountPercent'));
                    li.Tax_Rate__c = toDecimal(item.get('taxRate'));
                    li.Tax_Amount__c = toDecimal(item.get('taxAmount'));
                    li.Total_Amount__c = toDecimal(item.get('totalAmount'));
                    if (item.get('schemeId') != null) {
                        li.Scheme__c = (String) item.get('schemeId');
                    }
                    if (item.get('schemeDiscount') != null) {
                        li.Scheme_Discount__c = toDecimal(item.get('schemeDiscount'));
                    }
                    // Copy MRP / HSN from the product master so the saved
                    // line item is self-contained and reports don't need to
                    // chase back through Product_Ext__r at read-time.
                    if (prodId != null && productMetaMap.containsKey(prodId)) {
                        Product_Extension__c pe = productMetaMap.get(prodId);
                        li.MRP__c = pe.MRP__c;
                        li.HSN_SAC_Code__c = pe.HSN_SAC_Code__c;
                    }
                    // Store the Price_List__c Id the UI resolved (if any)
                    // so the draft-edit flow can re-open with the same
                    // pricing source applied. If the payload doesn't send
                    // one, OMS_OrderPricing_Service will stamp it during
                    // beforeInsert when it resolves the price.
                    if (item.get('priceListId') != null) {
                        li.Price_List__c = (String) item.get('priceListId');
                    }

                    // Set UOM picklist (backward compatibility)
                    String uomPicklist = item.get('uom') != null ? (String) item.get('uom') : null;
                    String uomCode = item.get('uomCode') != null ? (String) item.get('uomCode') : null;
                    if (String.isNotBlank(uomPicklist)) {
                        li.UOM__c = uomPicklist;
                    } else if (String.isNotBlank(uomCode)) {
                        li.UOM__c = UOM_Conversion_Service.mapCodeToPicklist(uomCode);
                    } else {
                        li.UOM__c = 'Pieces';
                    }

                    // Set UOM lookup fields
                    if (String.isNotBlank(uomCode)) {
                        li.Order_UOM__c = UOM_Conversion_Service.getUOMIdByCode(uomCode);
                    } else {
                        li.Order_UOM__c = UOM_Conversion_Service.getUOMIdByCode(
                            UOM_Conversion_Service.mapPicklistToCode(li.UOM__c)
                        );
                    }

                    // Set base quantity and conversion factor
                    li.Base_Quantity__c = conv.convertedQuantity;
                    li.Conversion_Factor__c = conv.conversionFactor;
                    li.Base_UOM__c = conv.baseUomId;

                    lineItems.add(li);
                }
            }

            if (!lineItems.isEmpty()) {
                // Identify must-sell product IDs — these bypass channel/category validation
                // since they're administratively mandated for this account/channel/territory
                Set<Id> mustSellProductIds = new Set<Id>();
                if (order.Account__c != null) {
                    Date effDate = order.Order_Date__c != null ? order.Order_Date__c : Date.today();
                    for (Must_Sell_Config__c cfg : [
                        SELECT Product_Ext__c FROM Must_Sell_Config__c
                        WHERE Is_Active__c = true
                          AND Start_Date__c <= :effDate
                          AND End_Date__c >= :effDate
                          AND Product_Ext__c != null
                    ]) {
                        mustSellProductIds.add(cfg.Product_Ext__c);
                    }
                }

                // MDM-004: Validate products against account's assigned categories
                if (BPM_FeatureToggle_Util.isEnabled('MDM-004') && order.Account__c != null) {
                    Set<Id> lineProductIds2 = new Set<Id>();
                    Map<Id, String> prodNameMap = new Map<Id, String>();
                    for (Order_Line_Item__c li : lineItems) {
                        // Skip must-sell products — they override category restrictions
                        if (li.Product_Ext__c != null && !mustSellProductIds.contains(li.Product_Ext__c)) {
                            lineProductIds2.add(li.Product_Ext__c);
                        }
                    }
                    if (!lineProductIds2.isEmpty()) {
                        for (Product_Extension__c pe : [SELECT Id, Name FROM Product_Extension__c WHERE Id IN :lineProductIds2]) {
                            prodNameMap.put(pe.Id, pe.Name);
                        }
                        Map<Id, Boolean> catAllowed = MDM_CategoryMapping_Service.validateProductsForAccount(
                            order.Account__c, lineProductIds2
                        );
                        List<String> blockedProducts = new List<String>();
                        for (Id pId : catAllowed.keySet()) {
                            if (!catAllowed.get(pId)) {
                                blockedProducts.add(prodNameMap.containsKey(pId) ? prodNameMap.get(pId) : String.valueOf(pId));
                            }
                        }
                        if (!blockedProducts.isEmpty()) {
                            throw new AuraHandledException(
                                'Products not in customer\'s assigned categories: ' + String.join(blockedProducts, ', ')
                            );
                        }
                    }
                }

                // MDM-003: Validate products against channel assignment
                if (BPM_FeatureToggle_Util.isEnabled('MDM-003') && String.isNotBlank(order.Trade_Channel__c)) {
                    Set<Id> lineProductIds3 = new Set<Id>();
                    for (Order_Line_Item__c li : lineItems) {
                        // Skip must-sell products — they override channel restrictions
                        if (li.Product_Ext__c != null && !mustSellProductIds.contains(li.Product_Ext__c)) {
                            lineProductIds3.add(li.Product_Ext__c);
                        }
                    }
                    if (!lineProductIds3.isEmpty()) {
                        List<Product_Extension__c> channelProds = [
                            SELECT Id, Name, Channels__c FROM Product_Extension__c WHERE Id IN :lineProductIds3
                        ];
                        List<String> channelBlocked = new List<String>();
                        for (Product_Extension__c pe : channelProds) {
                            if (!MDM_ChannelMapping_Service.isProductInChannel(pe, order.Trade_Channel__c)) {
                                channelBlocked.add(pe.Name);
                            }
                        }
                        if (!channelBlocked.isEmpty()) {
                            throw new AuraHandledException(
                                'Products not available in channel ' + order.Trade_Channel__c + ': ' + String.join(channelBlocked, ', ')
                            );
                        }
                    }
                }

                insert lineItems;
            }

            // Recalculate totals — this rebuilds Total_Amount / Net_Amount
            // etc. from line-item aggregates (which may use base-quantity
            // pricing and diverge from what the UI showed).
            updateOrderTotals(order.Id);

            // Reconcile the UI-facing Total_Gross_Amount__c /
            // Total_Net_Amount__c / Total_Tax__c / Total_Discount__c with
            // what the user confirmed on screen. updateOrderTotals above
            // (and the line-item trigger pipeline) can compute header
            // totals from base-quantity pricing, which produces different
            // numbers than the UI's qty*rate view. We treat the UI totals
            // as authoritative for these four 'Total_*' fields so the
            // order record's header matches what the user saw and saved.
            Sales_Order__c headerSync = new Sales_Order__c(Id = order.Id);
            Boolean doHeaderSync = false;
            if (payload.get('grossAmount') != null) {
                headerSync.Total_Gross_Amount__c = toDecimal(payload.get('grossAmount'));
                doHeaderSync = true;
            }
            if (payload.get('totalDiscount') != null) {
                headerSync.Total_Discount__c = toDecimal(payload.get('totalDiscount'));
                doHeaderSync = true;
            }
            if (payload.get('totalTax') != null) {
                headerSync.Total_Tax__c = toDecimal(payload.get('totalTax'));
                doHeaderSync = true;
            }
            if (payload.get('netAmount') != null && toDecimal(payload.get('netAmount')) > 0) {
                headerSync.Total_Net_Amount__c = toDecimal(payload.get('netAmount'));
                doHeaderSync = true;
            }
            if (doHeaderSync) {
                update headerSync;
            }

            // For edits, flip status to the caller's target now that the
            // fresh OLIs are in place and the must-sell validator can
            // count them. For new orders, status was already set on
            // insert so there's nothing more to do.
            if (isEdit && targetStatus != null && targetStatus != 'Draft') {
                update new Sales_Order__c(Id = order.Id, Status__c = targetStatus);
            }

            // Route a credit-flagged order into the approval engine (which
            // assigns the approver and manages the request/steps). The order
            // stays Submitted — the gated auto-approval flow leaves it pending —
            // until the approver decides. If routing fails (e.g. the submitter
            // has no manager to approve), the whole submit is rolled back by the
            // outer catch so there is no stuck, unrouted order — the rep gets a
            // clear reason and can retry once an approver is configured.
            if (requiresCreditApproval) {
                try {
                    // Use the rep's own approval comment when supplied (captured in
                    // the credit-approval modal); fall back to a default reason.
                    String approvalComment = (String) payload.get('approvalComment');
                    if (String.isBlank(approvalComment)) {
                        approvalComment = 'Order value exceeds the outlet credit limit.';
                    }
                    ApprovalRouter.submit(order.Id, approvalComment);
                } catch (Exception approvalEx) {
                    System.debug(LoggingLevel.ERROR, 'Credit approval routing failed: ' + approvalEx.getMessage());
                    throw new AuraHandledException(
                        'This order exceeds the credit limit and could not be routed for approval: '
                        + approvalEx.getMessage()
                        + ' A credit approver (the rep\'s manager) must be configured. The order was not submitted.');
                }
            }

            return [
                SELECT Id, Name, Status__c, Total_Net_Amount__c, Requires_Credit_Approval__c
                FROM Sales_Order__c WHERE Id = :order.Id
            ];
        } catch (Exception e) {
            Database.rollback(sp);
            // Log the full stack trace to server logs for debugging
            System.debug(LoggingLevel.ERROR, 'createSalesOrder failed: ' + e.getMessage()
                + '\nStack: ' + e.getStackTraceString()
                + '\nLine: ' + e.getLineNumber() + ', Type: ' + e.getTypeName());
            // AuraHandledException.getMessage() returns "Script-thrown exception" — use type-aware handling
            String errMsg = e.getMessage();
            if (e instanceof AuraHandledException) {
                // Already a user-friendly message, re-throw as-is
                throw e;
            }
            // For DML exceptions, try to extract the actual field error
            if (e instanceof DmlException) {
                DmlException dmlEx = (DmlException) e;
                if (dmlEx.getNumDml() > 0) {
                    errMsg = dmlEx.getDmlMessage(0);
                    if (String.isBlank(errMsg)) errMsg = dmlEx.getMessage();
                }
            }
            AuraHandledException aex = new AuraHandledException(errMsg);
            aex.setMessage(errMsg);
            throw aex;
        }
    }

    /**
     * @description Returns a Draft order plus its line items shaped for the
     *              orderEntryForm LWC to rehydrate its edit state. Only
     *              Draft orders are allowed through this path — submitted
     *              or approved orders must not be reopened for edit.
     * @param  orderId Sales_Order__c Id to load.
     * @return Map with header (accountId, visitId, remarks, status,
     *         mustSellOverride, mustSellCompliance, totals) and a list of
     *         'lineItems' — each carrying productId, productName, sku,
     *         quantity, baseQuantity, freeQty, uom, uomCode, baseUOMCode,
     *         rate, grossAmount, discountAmount, taxRate, taxAmount,
     *         totalAmount, schemeId, schemeName, priceListId,
     *         priceListName, classification hints.
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getDraftOrder(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('orderId is required.');
        }
        List<Sales_Order__c> orders = [
            SELECT Id, Name, Status__c, Account__c, Visit__c, Warehouse__c,
                   Notes__c, Total_Gross_Amount__c, Total_Discount__c,
                   Total_Tax__c, Total_Net_Amount__c, Must_Sell_Override__c,
                   Must_Sell_Compliance__c
            FROM Sales_Order__c
            WHERE Id = :orderId LIMIT 1
        ];
        if (orders.isEmpty()) {
            throw new AuraHandledException('Order not found.');
        }
        Sales_Order__c o = orders[0];
        if (o.Status__c != 'Draft') {
            throw new AuraHandledException(
                'Only Draft orders can be edited. Order is currently ' + o.Status__c + '.'
            );
        }

        List<Order_Line_Item__c> lis = [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Product_Ext__r.Unit_of_Measure__c, Product_Ext__r.MRP__c,
                   Product_Ext__r.Base_UOM__c, Product_Ext__r.Base_UOM__r.UOM_Code__c,
                   Quantity__c, Base_Quantity__c, Conversion_Factor__c,
                   Free_Quantity__c, Unit_Price__c,
                   UOM__c, Order_UOM__c, Order_UOM__r.UOM_Code__c,
                   Line_Total__c, Discount_Amount__c, Discount_Percent__c,
                   Tax_Rate__c, Tax_Amount__c, Total_Amount__c,
                   Scheme__c, Scheme__r.Name,
                   Price_List__c, Price_List__r.Name
            FROM Order_Line_Item__c
            WHERE Sales_Order__c = :orderId
            ORDER BY CreatedDate ASC
        ];

        List<Map<String, Object>> liMaps = new List<Map<String, Object>>();
        for (Order_Line_Item__c li : lis) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('lineId', li.Id);
            m.put('productId', li.Product_Ext__c);
            m.put('productName', li.Product_Ext__r != null ? li.Product_Ext__r.Name : null);
            m.put('sku', li.Product_Ext__r != null ? li.Product_Ext__r.SKU_Code__c : null);
            m.put('mrp', li.Product_Ext__r != null ? li.Product_Ext__r.MRP__c : null);
            m.put('quantity', li.Quantity__c);
            m.put('baseQuantity', li.Base_Quantity__c);
            m.put('conversionFactor', li.Conversion_Factor__c);
            m.put('freeQty', li.Free_Quantity__c);
            m.put('rate', li.Unit_Price__c);
            m.put('uom', li.UOM__c);
            m.put('uomCode', li.Order_UOM__r != null ? li.Order_UOM__r.UOM_Code__c : null);
            m.put('baseUOMCode', (li.Product_Ext__r != null && li.Product_Ext__r.Base_UOM__r != null)
                ? li.Product_Ext__r.Base_UOM__r.UOM_Code__c : 'PCS');
            m.put('grossAmount', li.Line_Total__c);
            m.put('discountAmount', li.Discount_Amount__c);
            m.put('discountPercent', li.Discount_Percent__c);
            m.put('taxRate', li.Tax_Rate__c);
            m.put('taxAmount', li.Tax_Amount__c);
            m.put('totalAmount', li.Total_Amount__c);
            m.put('schemeId', li.Scheme__c);
            m.put('schemeName', li.Scheme__r != null ? li.Scheme__r.Name : null);
            m.put('priceListId', li.Price_List__c);
            m.put('priceListName', li.Price_List__r != null ? li.Price_List__r.Name : null);
            liMaps.add(m);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('orderId', o.Id);
        result.put('orderName', o.Name);
        result.put('accountId', o.Account__c);
        result.put('visitId', o.Visit__c);
        result.put('warehouseId', o.Warehouse__c);
        result.put('status', o.Status__c);
        result.put('remarks', o.Notes__c);
        result.put('grossAmount', o.Total_Gross_Amount__c);
        result.put('totalDiscount', o.Total_Discount__c);
        result.put('totalTax', o.Total_Tax__c);
        result.put('netAmount', o.Total_Net_Amount__c);
        result.put('mustSellOverride', o.Must_Sell_Override__c);
        result.put('mustSellCompliance', o.Must_Sell_Compliance__c);
        result.put('lineItems', liMaps);
        return result;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        if (value instanceof Double) return Decimal.valueOf((Double) value);
        return Decimal.valueOf(String.valueOf(value));
    }

    @AuraEnabled(cacheable=true)
    public static Sales_Order__c getLastOrder(Id accountId) {
        List<Sales_Order__c> orders = [
            SELECT Id, Name, Order_Date__c, Total_Net_Amount__c, Status__c, Net_Amount__c,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                           Product_Ext__r.Base_UOM__c, Product_Ext__r.Base_UOM__r.UOM_Code__c,
                           Quantity__c, Base_Quantity__c, Unit_Price__c, Line_Total__c,
                           UOM__c, Order_UOM__c, Base_UOM__c, Conversion_Factor__c,
                           Free_Quantity__c, Discount_Amount__c, Tax_Rate__c, Tax_Amount__c, Total_Amount__c
                    FROM Order_Line_Items__r ORDER BY CreatedDate)
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            ORDER BY Order_Date__c DESC
            LIMIT 1
        ];
        return orders.isEmpty() ? null : orders[0];
    }

    @AuraEnabled(cacheable=true)
    public static List<Scheme__c> getApplicableSchemes(Id accountId, Date orderDate) {
        Date effectiveDate = orderDate != null ? orderDate : Date.today();
        return [
            SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c, Description__c,
                   Start_Date__c, End_Date__c, Max_Discount_Cap__c,
                   Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                   Free_Product_Ext__c, Free_Product_Ext__r.Name, Free_Quantity__c,
                   Reward_Points__c, MOV__c, Min_Quantity__c, Max_Quantity__c,
                   Min_Value__c, Max_Value__c, Product_Ext__c, Product_Category__c,
                   Invoice_Qty_Threshold__c, Invoice_Qty_UOM__c, Invoice_Val_Threshold__c,
                   Is_Stackable__c, Priority__c,
                   (SELECT Id, Slab_Type__c, Min_Quantity__c, Max_Quantity__c,
                           Min_Value__c, Max_Value__c,
                           Discount_Type__c, Discount_Value__c, Discount_Percent__c,
                           Discount_Amount__c, Free_Product_Ext__c, Free_Quantity__c,
                           Price_Discount__c, Reward_Points__c
                    FROM Scheme_Slabs__r WHERE Is_Active__c = true ORDER BY Min_Quantity__c ASC, Min_Value__c ASC),
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Is_Buy_Product__c, Is_Get_Product__c,
                           Min_Quantity__c, Product_Classification__c
                    FROM Scheme_Products__r)
            FROM Scheme__c
            WHERE Status__c = 'Active'
            AND Start_Date__c <= :effectiveDate
            AND End_Date__c >= :effectiveDate
            ORDER BY Priority__c
        ];
    }

    /**
     * @description Credit position for an outlet, so the order form can warn
     *              before a submit pushes the outlet past its limit. Returns the
     *              limit, current outstanding, and the resulting available credit.
     *              availableCredit is limit - outstanding; a limit of 0 means no
     *              ceiling is configured and the caller should not block.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAccountCredit(Id accountId) {
        Map<String, Object> out = new Map<String, Object>{
            'accountName' => null,
            'creditLimit' => 0,
            'outstanding' => 0,
            'availableCredit' => 0
        };
        if (accountId == null) return out;
        List<Account> accts = [
            SELECT Name, Credit_Limit__c, Credit_Utilized__c, Outstanding_Balance__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        if (accts.isEmpty()) return out;
        Account a = accts[0];
        Decimal limitAmt = a.Credit_Limit__c != null ? a.Credit_Limit__c : 0;
        // Exposure = greater of the two divergent credit fields.
        Decimal outstanding = Math.max(
            a.Credit_Utilized__c != null ? a.Credit_Utilized__c : 0,
            a.Outstanding_Balance__c != null ? a.Outstanding_Balance__c : 0
        );
        out.put('accountName', a.Name);
        out.put('creditLimit', limitAmt);
        out.put('outstanding', outstanding);
        out.put('availableCredit', limitAmt - outstanding);
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMustSellProducts(Id accountId, Date orderDate) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (!BPM_FeatureToggle_Util.isEnabled('SPM-002')) {
            return result;
        }

        Date effectiveDate = orderDate != null ? orderDate : Date.today();

        // Fetch account attributes for filtering
        String accountChannel = '';
        String accountCustomerType = '';
        Id accountTerritoryId = null;

        if (accountId != null) {
            List<Account> accts = [
                SELECT Channel__c, Outlet_Type__c, Territory__c
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];
            if (!accts.isEmpty()) {
                accountChannel = accts[0].Channel__c != null ? accts[0].Channel__c : '';
                accountCustomerType = accts[0].Outlet_Type__c != null ? accts[0].Outlet_Type__c : '';
                accountTerritoryId = accts[0].Territory__c;
            }
        }

        // Query Must_Sell_Config__c records that are active and within date range
        List<Must_Sell_Config__c> configs = [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Product_Ext__r.Unit_of_Measure__c,
                   Product_Ext__r.Base_UOM__c, Product_Ext__r.Base_UOM__r.UOM_Code__c, Product_Ext__r.Base_UOM__r.Name,
                   Product_Ext__r.Secondary_UOM__c, Product_Ext__r.Secondary_UOM__r.UOM_Code__c, Product_Ext__r.Secondary_UOM__r.Name,
                   Product_Ext__r.Ordering_UOMs__c, Product_Ext__r.Case_Size__c,
                   Product_Ext__r.MRP__c, Product_Ext__r.Unit_Price__c, Product_Ext__r.GST_Rate__c,
                   Classification__c, Min_Qty__c,
                   Territory__c, Channel__c, Customer_Type__c
            FROM Must_Sell_Config__c
            WHERE Is_Active__c = true
              AND Start_Date__c <= :effectiveDate
              AND End_Date__c >= :effectiveDate
              AND Product_Ext__c != null
            ORDER BY Classification__c, Product_Ext__r.Name
        ];

        // Collect all candidate product IDs for price resolution
        Set<Id> allMustSellProductIds = new Set<Id>();
        for (Must_Sell_Config__c cfg : configs) {
            allMustSellProductIds.add(cfg.Product_Ext__c);
        }

        // Fetch product categories for priority-based pricing
        Map<Id, Id> msCategoryMap = new Map<Id, Id>();
        for (Product_Extension__c pe : [
            SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id IN :allMustSellProductIds
        ]) {
            if (pe.Product_Category__c != null) {
                msCategoryMap.put(pe.Id, pe.Product_Category__c);
            }
        }

        // Resolve prices using full priority hierarchy from Price_List__c
        Map<Id, Decimal> msPriceMap = resolvePricesByPriority(
            allMustSellProductIds, accountId, accountTerritoryId, accountChannel, msCategoryMap
        );

        // Filter configs by account's territory, channel, and customer type
        Set<Id> seenProductIds = new Set<Id>();
        for (Must_Sell_Config__c cfg : configs) {
            // Territory filter: config applies if territory is blank (all) or matches account
            if (cfg.Territory__c != null && cfg.Territory__c != accountTerritoryId) {
                continue;
            }
            // Channel filter: config applies if channel is blank (all) or matches account
            if (String.isNotBlank(cfg.Channel__c) && cfg.Channel__c != accountChannel) {
                continue;
            }
            // Customer Type filter: config applies if customer type is blank (all) or matches account
            if (String.isNotBlank(cfg.Customer_Type__c) && cfg.Customer_Type__c != accountCustomerType) {
                continue;
            }

            // Deduplicate by product Id — first matching config wins
            if (seenProductIds.contains(cfg.Product_Ext__c)) {
                continue;
            }
            seenProductIds.add(cfg.Product_Ext__c);

            // Use priority-resolved price > product Unit_Price > MRP as fallback
            Decimal resolvedUnitPrice = msPriceMap.get(cfg.Product_Ext__c);
            Decimal unitPrice = (resolvedUnitPrice != null && resolvedUnitPrice > 0)
                ? resolvedUnitPrice
                : (cfg.Product_Ext__r.Unit_Price__c != null ? cfg.Product_Ext__r.Unit_Price__c : cfg.Product_Ext__r.MRP__c);

            Map<String, Object> item = new Map<String, Object>();
            item.put('productId', cfg.Product_Ext__c);
            item.put('productName', cfg.Product_Ext__r.Name);
            item.put('sku', cfg.Product_Ext__r.SKU_Code__c);
            item.put('minQuantity', cfg.Min_Qty__c != null ? cfg.Min_Qty__c : 1);
            item.put('classification', cfg.Classification__c);
            item.put('configId', cfg.Id);
            item.put('uom', cfg.Product_Ext__r.Unit_of_Measure__c != null ? cfg.Product_Ext__r.Unit_of_Measure__c : 'Piece');
            item.put('baseUOMCode', (cfg.Product_Ext__r.Base_UOM__c != null && cfg.Product_Ext__r.Base_UOM__r.UOM_Code__c != null) ? cfg.Product_Ext__r.Base_UOM__r.UOM_Code__c : 'PCS');
            item.put('baseUOMName', (cfg.Product_Ext__r.Base_UOM__c != null && cfg.Product_Ext__r.Base_UOM__r.Name != null) ? cfg.Product_Ext__r.Base_UOM__r.Name : 'Piece');
            item.put('secondaryUOMCode', (cfg.Product_Ext__r.Secondary_UOM__c != null && cfg.Product_Ext__r.Secondary_UOM__r.UOM_Code__c != null) ? cfg.Product_Ext__r.Secondary_UOM__r.UOM_Code__c : null);
            item.put('secondaryUOMName', (cfg.Product_Ext__r.Secondary_UOM__c != null && cfg.Product_Ext__r.Secondary_UOM__r.Name != null) ? cfg.Product_Ext__r.Secondary_UOM__r.Name : null);
            item.put('orderingUOMs', cfg.Product_Ext__r.Ordering_UOMs__c);
            item.put('caseSize', cfg.Product_Ext__r.Case_Size__c);
            item.put('categoryId', msCategoryMap.containsKey(cfg.Product_Ext__c) ? msCategoryMap.get(cfg.Product_Ext__c) : null);
            item.put('mrp', cfg.Product_Ext__r.MRP__c);
            item.put('unitPrice', unitPrice);
            item.put('gstRate', cfg.Product_Ext__r.GST_Rate__c);
            result.add(item);
        }

        // Also include legacy scheme-based must-sell products (backward compatibility)
        List<Scheme__c> schemes = [
            SELECT Id, Name,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                           Product_Ext__r.Unit_of_Measure__c,
                           Product_Ext__r.Base_UOM__c, Product_Ext__r.Base_UOM__r.UOM_Code__c, Product_Ext__r.Base_UOM__r.Name,
                           Product_Ext__r.Secondary_UOM__c, Product_Ext__r.Secondary_UOM__r.UOM_Code__c, Product_Ext__r.Secondary_UOM__r.Name,
                           Product_Ext__r.Ordering_UOMs__c, Product_Ext__r.Case_Size__c,
                           Product_Ext__r.MRP__c, Product_Ext__r.Unit_Price__c, Product_Ext__r.GST_Rate__c,
                           Min_Quantity__c, Product_Classification__c
                    FROM Scheme_Products__r
                    WHERE Product_Classification__c IN ('Must Sell', 'Focused Sell')
                      AND Product_Ext__c != null)
            FROM Scheme__c
            WHERE Status__c = 'Active'
            AND Start_Date__c <= :effectiveDate
            AND End_Date__c >= :effectiveDate
            ORDER BY Priority__c
        ];

        // Collect scheme product IDs for price resolution
        Set<Id> schemeProductIds = new Set<Id>();
        for (Scheme__c scheme : schemes) {
            if (scheme.Scheme_Products__r == null) continue;
            for (Scheme_Product__c sp : scheme.Scheme_Products__r) {
                if (!seenProductIds.contains(sp.Product_Ext__c)) {
                    schemeProductIds.add(sp.Product_Ext__c);
                }
            }
        }

        // Resolve prices for scheme products using priority hierarchy
        Map<Id, Id> schemeProdCategoryMap = new Map<Id, Id>();
        if (!schemeProductIds.isEmpty()) {
            for (Product_Extension__c pe : [
                SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id IN :schemeProductIds
            ]) {
                if (pe.Product_Category__c != null) {
                    schemeProdCategoryMap.put(pe.Id, pe.Product_Category__c);
                }
            }
        }
        Map<Id, Decimal> schemePriceMap = resolvePricesByPriority(
            schemeProductIds, accountId, accountTerritoryId, accountChannel, schemeProdCategoryMap
        );

        for (Scheme__c scheme : schemes) {
            if (scheme.Scheme_Products__r == null) continue;
            for (Scheme_Product__c sp : scheme.Scheme_Products__r) {
                if (seenProductIds.contains(sp.Product_Ext__c)) continue;
                seenProductIds.add(sp.Product_Ext__c);

                // Use priority-resolved price > product Unit_Price > MRP as fallback
                Decimal spResolvedPrice = schemePriceMap.get(sp.Product_Ext__c);
                Decimal spUnitPrice = (spResolvedPrice != null && spResolvedPrice > 0)
                    ? spResolvedPrice
                    : (sp.Product_Ext__r.Unit_Price__c != null ? sp.Product_Ext__r.Unit_Price__c : sp.Product_Ext__r.MRP__c);

                Map<String, Object> item = new Map<String, Object>();
                item.put('productId', sp.Product_Ext__c);
                item.put('productName', sp.Product_Ext__r.Name);
                item.put('sku', sp.Product_Ext__r.SKU_Code__c);
                item.put('minQuantity', sp.Min_Quantity__c != null ? sp.Min_Quantity__c : 1);
                item.put('schemeName', scheme.Name);
                item.put('schemeId', scheme.Id);
                item.put('classification', sp.Product_Classification__c);
                item.put('uom', sp.Product_Ext__r.Unit_of_Measure__c != null ? sp.Product_Ext__r.Unit_of_Measure__c : 'Piece');
                item.put('baseUOMCode', (sp.Product_Ext__r.Base_UOM__c != null && sp.Product_Ext__r.Base_UOM__r.UOM_Code__c != null) ? sp.Product_Ext__r.Base_UOM__r.UOM_Code__c : 'PCS');
                item.put('baseUOMName', (sp.Product_Ext__r.Base_UOM__c != null && sp.Product_Ext__r.Base_UOM__r.Name != null) ? sp.Product_Ext__r.Base_UOM__r.Name : 'Piece');
                item.put('secondaryUOMCode', (sp.Product_Ext__r.Secondary_UOM__c != null && sp.Product_Ext__r.Secondary_UOM__r.UOM_Code__c != null) ? sp.Product_Ext__r.Secondary_UOM__r.UOM_Code__c : null);
                item.put('secondaryUOMName', (sp.Product_Ext__r.Secondary_UOM__c != null && sp.Product_Ext__r.Secondary_UOM__r.Name != null) ? sp.Product_Ext__r.Secondary_UOM__r.Name : null);
                item.put('orderingUOMs', sp.Product_Ext__r.Ordering_UOMs__c);
                item.put('caseSize', sp.Product_Ext__r.Case_Size__c);
                item.put('mrp', sp.Product_Ext__r.MRP__c);
                item.put('unitPrice', spUnitPrice);
                item.put('gstRate', sp.Product_Ext__r.GST_Rate__c);
                result.add(item);
            }
        }

        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProductSearchResult> getTopSellingProducts(Id accountId) {
        // Get top selling products based on order frequency for this account's territory
        Set<Id> topProductIds = new Set<Id>();

        // Fetch account details for price resolution
        String tsChannel = '';
        Id tsTerritoryId = null;
        if (accountId != null) {
            List<Account> accts = [SELECT Channel__c, Territory__c FROM Account WHERE Id = :accountId LIMIT 1];
            if (!accts.isEmpty()) {
                tsChannel = accts[0].Channel__c != null ? accts[0].Channel__c : '';
                tsTerritoryId = accts[0].Territory__c;
            }
        }

        // First: top products ordered by this specific account
        for (AggregateResult ar : [
            SELECT Product_Ext__c prodId, COUNT(Id) cnt
            FROM Order_Line_Item__c
            WHERE Sales_Order__r.Account__c = :accountId
              AND Sales_Order__r.Status__c != 'Cancelled'
              AND Sales_Order__r.Order_Date__c >= :Date.today().addDays(-90)
            GROUP BY Product_Ext__c
            ORDER BY COUNT(Id) DESC
            LIMIT 10
        ]) {
            topProductIds.add((Id) ar.get('prodId'));
        }

        // If less than 10, supplement with territory-wide top sellers
        if (topProductIds.size() < 10) {
            if (tsTerritoryId != null) {
                for (AggregateResult ar : [
                    SELECT Product_Ext__c prodId, COUNT(Id) cnt
                    FROM Order_Line_Item__c
                    WHERE Sales_Order__r.Account__r.Territory__c = :tsTerritoryId
                      AND Sales_Order__r.Status__c != 'Cancelled'
                      AND Sales_Order__r.Order_Date__c >= :Date.today().addDays(-90)
                      AND Product_Ext__c NOT IN :topProductIds
                    GROUP BY Product_Ext__c
                    ORDER BY COUNT(Id) DESC
                    LIMIT :( 10 - topProductIds.size() )
                ]) {
                    topProductIds.add((Id) ar.get('prodId'));
                }
            }
        }

        // Fallback: if no top sellers found, show recently added active products
        if (topProductIds.isEmpty()) {
            List<Product_Extension__c> fallbackProducts = [
                SELECT Id, Name, SKU_Code__c, MRP__c, Unit_Price__c, GST_Rate__c, Unit_of_Measure__c,
                       Base_UOM__c, Base_UOM__r.UOM_Code__c, Base_UOM__r.Name,
                       Secondary_UOM__c, Secondary_UOM__r.UOM_Code__c, Secondary_UOM__r.Name,
                       Ordering_UOMs__c, Case_Size__c, Product_Category__c
                FROM Product_Extension__c
                WHERE Is_Active__c = true
                ORDER BY CreatedDate DESC
                LIMIT 10
            ];
            Set<Id> fallbackIds = new Set<Id>();
            Map<Id, Id> fallbackCatMap = new Map<Id, Id>();
            for (Product_Extension__c p : fallbackProducts) {
                fallbackIds.add(p.Id);
                if (p.Product_Category__c != null) {
                    fallbackCatMap.put(p.Id, p.Product_Category__c);
                }
            }
            Map<Id, Decimal> fallbackPrices = resolvePricesByPriority(
                fallbackIds, accountId, tsTerritoryId, tsChannel, fallbackCatMap
            );
            List<ProductSearchResult> fallbackResults = new List<ProductSearchResult>();
            for (Product_Extension__c p : fallbackProducts) {
                ProductSearchResult r = buildProductSearchResult(p);
                Decimal resolved = fallbackPrices.get(p.Id);
                if (resolved != null && resolved > 0) {
                    r.Unit_Price = resolved;
                }
                fallbackResults.add(r);
            }
            return fallbackResults;
        }

        List<Product_Extension__c> products = [
            SELECT Id, Name, SKU_Code__c, MRP__c, Unit_Price__c, GST_Rate__c, Unit_of_Measure__c,
                   Base_UOM__c, Base_UOM__r.UOM_Code__c, Base_UOM__r.Name,
                   Secondary_UOM__c, Secondary_UOM__r.UOM_Code__c, Secondary_UOM__r.Name,
                   Ordering_UOMs__c, Case_Size__c, Product_Category__c
            FROM Product_Extension__c
            WHERE Id IN :topProductIds AND Is_Active__c = true
        ];

        // Resolve prices using full priority hierarchy
        Map<Id, Id> tsCategoryMap = new Map<Id, Id>();
        for (Product_Extension__c p : products) {
            if (p.Product_Category__c != null) {
                tsCategoryMap.put(p.Id, p.Product_Category__c);
            }
        }
        Map<Id, Decimal> tsPriceMap = resolvePricesByPriority(
            topProductIds, accountId, tsTerritoryId, tsChannel, tsCategoryMap
        );

        List<ProductSearchResult> results = new List<ProductSearchResult>();
        for (Product_Extension__c p : products) {
            ProductSearchResult r = buildProductSearchResult(p);
            Decimal resolved = tsPriceMap.get(p.Id);
            if (resolved != null && resolved > 0) {
                r.Unit_Price = resolved;
            }
            results.add(r);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> getProductExtensions(List<Id> productIds) {
        return [SELECT Id, HSN_SAC_Code__c, Barcode_UPC__c, Barcode_EAN__c,
                       Case_Size__c, Min_Order_Qty__c, Weight__c, Weight_Unit__c
                FROM Product_Extension__c WHERE Id IN :productIds];
    }

    public class ProductSearchResult {
        @AuraEnabled public Id Id;
        @AuraEnabled public String Name;
        @AuraEnabled public String SKU_Code;
        @AuraEnabled public String ImageUrl;
        @AuraEnabled public Decimal MRP;
        @AuraEnabled public Decimal Unit_Price;
        @AuraEnabled public Decimal GST_Rate;
        @AuraEnabled public String UOM;
        @AuraEnabled public String BaseUOMCode;
        @AuraEnabled public Id BaseUOMId;
        @AuraEnabled public String BaseUOMName;
        @AuraEnabled public String SecondaryUOMCode;
        @AuraEnabled public Id SecondaryUOMId;
        @AuraEnabled public String SecondaryUOMName;
        @AuraEnabled public String OrderingUOMs;
        @AuraEnabled public Decimal CaseSize;
        @AuraEnabled public Id Product_Category;
    }

    /**
     * @description Returns the available UOM options for order line items.
     *              Maps product UOM values to Order_Line_Item__c.UOM__c picklist values.
     * @return List of label/value pairs for UOM combobox.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getOrderUOMOptions() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        // Query all active UOMs from the UOM master table
        List<UOM__c> activeUOMs = [
            SELECT Id, UOM_Code__c, Name, Is_Base_Unit__c
            FROM UOM__c
            WHERE Is_Active__c = true
            ORDER BY Is_Base_Unit__c DESC, Name ASC
        ];
        if (!activeUOMs.isEmpty()) {
            for (UOM__c u : activeUOMs) {
                Map<String, String> opt = new Map<String, String>();
                opt.put('label', u.Name + ' (' + u.UOM_Code__c + ')');
                opt.put('value', u.UOM_Code__c);
                opt.put('uomId', u.Id);
                opt.put('isBase', String.valueOf(u.Is_Base_Unit__c));
                options.add(opt);
            }
        }
        // Fallback to hardcoded values if no UOM master records exist
        if (options.isEmpty()) {
            String[] uomValues = new String[]{ 'Pieces', 'Cases', 'Boxes', 'Kg', 'Liters' };
            for (String uom : uomValues) {
                Map<String, String> opt = new Map<String, String>();
                opt.put('label', uom);
                opt.put('value', uom);
                options.add(opt);
            }
        }
        return options;
    }

    /**
     * @description Returns allowed UOM options for a specific product, using
     *              the UOM master and product configuration.
     * @param productId The Product_Extension__c Id.
     * @return List of maps with label, value (UOM code), uomId, isBase keys.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getProductUOMOptions(Id productId) {
        return UOM_Conversion_Service.getProductUOMOptions(productId);
    }

    /**
     * @description Converts a quantity between UOMs for a product. Used by LWC
     *              to display the base quantity equivalent inline.
     * @param productId The Product_Extension__c Id.
     * @param fromUomCode Source UOM code (e.g., 'CS').
     * @param toUomCode Target UOM code (e.g., 'PC').
     * @param quantity The quantity to convert.
     * @return Map with convertedQuantity and conversionFactor.
     */
    @AuraEnabled
    public static Map<String, Decimal> convertQuantity(Id productId, String fromUomCode, String toUomCode, Decimal quantity) {
        Map<String, Decimal> result = new Map<String, Decimal>();
        Decimal factor = UOM_Conversion_Service.getConversionFactor(productId, fromUomCode, toUomCode);
        result.put('conversionFactor', factor);
        result.put('convertedQuantity', quantity != null ? quantity * factor : 0);
        // Flag: 1 = valid conversion found, 0 = defaulted to 1 (no rule)
        result.put('hasConversion', (fromUomCode == toUomCode || factor != 1) ? 1 : 0);
        return result;
    }

    /**
     * @description Maps a Product_Extension__c.Unit_of_Measure__c value to
     *              the corresponding Order_Line_Item__c.UOM__c picklist value.
     * @param productUOM The product's Unit_of_Measure__c value.
     * @return The matching Order_Line_Item__c.UOM__c picklist value.
     */
    public static String mapProductUOMToOrderUOM(String productUOM) {
        if (String.isBlank(productUOM)) return 'Pieces';
        Map<String, String> mapping = new Map<String, String>{
            'Piece' => 'Pieces',
            'Box' => 'Boxes',
            'Case' => 'Cases',
            'Kg' => 'Kg',
            'Litre' => 'Liters',
            'Dozen' => 'Pieces',
            'Pack' => 'Pieces'
        };
        return mapping.containsKey(productUOM) ? mapping.get(productUOM) : 'Pieces';
    }

    private static ProductSearchResult buildProductSearchResult(Product_Extension__c p) {
        ProductSearchResult r = new ProductSearchResult();
        r.Id = p.Id;
        r.Name = p.Name;
        r.SKU_Code = p.SKU_Code__c;
        r.MRP = p.MRP__c;
        r.Unit_Price = p.Unit_Price__c != null ? p.Unit_Price__c : p.MRP__c;
        r.GST_Rate = p.GST_Rate__c;
        r.UOM = p.Unit_of_Measure__c != null ? p.Unit_of_Measure__c : 'Piece';
        r.BaseUOMCode = (p.Base_UOM__c != null && p.Base_UOM__r.UOM_Code__c != null)
            ? p.Base_UOM__r.UOM_Code__c : 'PCS';
        r.BaseUOMId = p.Base_UOM__c;
        r.BaseUOMName = (p.Base_UOM__c != null && p.Base_UOM__r.Name != null)
            ? p.Base_UOM__r.Name : 'Piece';
        r.SecondaryUOMCode = (p.Secondary_UOM__c != null && p.Secondary_UOM__r.UOM_Code__c != null)
            ? p.Secondary_UOM__r.UOM_Code__c : null;
        r.SecondaryUOMId = p.Secondary_UOM__c;
        r.SecondaryUOMName = (p.Secondary_UOM__c != null && p.Secondary_UOM__r.Name != null)
            ? p.Secondary_UOM__r.Name : null;
        r.OrderingUOMs = p.Ordering_UOMs__c;
        r.CaseSize = p.Case_Size__c;
        r.Product_Category = p.Product_Category__c;
        return r;
    }

    private static void updateOrderTotals(Id orderId) {
        AggregateResult[] results = [
            SELECT SUM(Line_Total__c) totalAmount, SUM(Line_Amount__c) lineAmount,
                   SUM(Tax_Amount__c) totalTax,
                   SUM(Discount_Amount__c) totalDiscount,
                   SUM(Scheme_Discount__c) totalSchemeDiscount,
                   SUM(Total_Amount__c) totalNet,
                   SUM(Free_Quantity__c) totalFreeQty,
                   SUM(Reward_Points__c) totalRewardPts,
                   COUNT(Id) totalItems
            FROM Order_Line_Item__c WHERE Sales_Order__c = :orderId
        ];
        if (!results.isEmpty()) {
            Sales_Order__c order = new Sales_Order__c(Id = orderId);
            Decimal lineAmount = results[0].get('lineAmount') != null ? (Decimal)results[0].get('lineAmount') : 0;
            Decimal totalAmount = results[0].get('totalAmount') != null ? (Decimal)results[0].get('totalAmount') : 0;
            Decimal tax = results[0].get('totalTax') != null ? (Decimal)results[0].get('totalTax') : 0;
            Decimal disc = results[0].get('totalDiscount') != null ? (Decimal)results[0].get('totalDiscount') : 0;
            Decimal schemeDisc = results[0].get('totalSchemeDiscount') != null ? (Decimal)results[0].get('totalSchemeDiscount') : 0;
            Decimal totalNet = results[0].get('totalNet') != null ? (Decimal)results[0].get('totalNet') : 0;
            Decimal freeQty = results[0].get('totalFreeQty') != null ? (Decimal)results[0].get('totalFreeQty') : 0;
            Decimal rewardPts = results[0].get('totalRewardPts') != null ? (Decimal)results[0].get('totalRewardPts') : 0;

            // Align with trigger handler field mappings
            order.Total_Amount__c = lineAmount;
            order.Total_Gross_Amount__c = totalAmount > 0 ? totalAmount : lineAmount;
            order.Total_Tax__c = tax;
            order.Total_Discount__c = disc;
            order.Discount_Amount__c = disc + schemeDisc;
            order.Scheme_Discount__c = schemeDisc;
            order.Total_Net_Amount__c = totalNet > 0 ? totalNet : (lineAmount - disc - schemeDisc + tax);
            order.Net_Amount__c = totalNet > 0 ? totalNet : (lineAmount - disc - schemeDisc + tax);
            order.Total_Items__c = (Integer)results[0].get('totalItems');
            order.Total_Free_Quantity__c = freeQty;
            order.Total_Reward_Points__c = rewardPts.intValue();
            update order;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getProductCategories() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        Map<String, String> allOption = new Map<String, String>();
        allOption.put('label', 'All Categories');
        allOption.put('value', '');
        options.add(allOption);
        for (Product_Category__c cat : [
            SELECT Id, Name FROM Product_Category__c
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c NULLS LAST, Name
        ]) {
            Map<String, String> opt = new Map<String, String>();
            opt.put('label', cat.Name);
            opt.put('value', cat.Name);
            options.add(opt);
        }
        return options;
    }

    /**
     * @description Returns active warehouses for the warehouse selection dropdown.
     * @return List of warehouse options with Id and Name.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getWarehouses() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Warehouse__c wh : [
            SELECT Id, Name, Warehouse_Code__c, Warehouse_Type__c, State__c, City__c
            FROM Warehouse__c
            WHERE Is_Active__c = true
            ORDER BY Name ASC
        ]) {
            Map<String, String> opt = new Map<String, String>();
            String label = wh.Name;
            if (String.isNotBlank(wh.Warehouse_Code__c)) {
                label += ' (' + wh.Warehouse_Code__c + ')';
            }
            if (String.isNotBlank(wh.City__c)) {
                label += ' - ' + wh.City__c;
            }
            opt.put('label', label);
            opt.put('value', wh.Id);
            opt.put('warehouseType', wh.Warehouse_Type__c != null ? wh.Warehouse_Type__c : '');
            opt.put('state', wh.State__c != null ? wh.State__c : '');
            options.add(opt);
        }
        return options;
    }

    /**
     * @description Checks stock availability for given products at a warehouse.
     *              Does NOT restrict order creation - only shows available quantities.
     * @param warehouseId The warehouse to check stock at.
     * @param productIds  List of product Ids to check.
     * @return Map of Product Id to available quantity (on hand minus reserved).
     */
    @AuraEnabled
    public static Map<Id, Decimal> checkStockAvailability(Id warehouseId, List<Id> productIds) {
        if (warehouseId == null || productIds == null || productIds.isEmpty()) {
            return new Map<Id, Decimal>();
        }
        return INV_WarehouseStock_Service.checkAvailability(warehouseId, productIds);
    }
}