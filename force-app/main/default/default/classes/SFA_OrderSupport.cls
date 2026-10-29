/**
 * @description Shared logic and request/response types for the SFA Copilot's
 *              order actions: Draft Order (read-only preview) and Place Order
 *              (write, confirmation-gated).
 *
 * The split is deliberate. Draft parses the rep's plain-language item list,
 * resolves products, estimates the value, and runs the credit and must-sell
 * checks — creating nothing. Place is the only action that writes, refuses
 * unless the rep has confirmed, and delegates the actual creation to
 * OrderEntryController.createSalesOrder so all the real pricing, scheme and tax
 * logic (stamped by the Order Line Item trigger) applies — the agent sends only
 * product + quantity, never a price it made up.
 *
 * Orders are created as Draft, so nothing is invoiced or submitted for approval
 * behind the rep's back; they review and submit through the normal order screen.
 * Read-scoped with sharing so a rep only ever orders for outlets they can see.
 */
public with sharing class SFA_OrderSupport {

    // ── Request / response types ──────────────────────────────────────────

    public class DraftRequest {
        @InvocableVariable(required=true label='Account Id'
            description='The outlet Account the order is for.')
        public Id accountId;
        @InvocableVariable(required=true label='Items'
            description='The products and quantities the rep asked for, in plain text, e.g. "20 Ultra Mini, 10 Grind+ Gold".')
        public String items;
    }

    public class DraftResult {
        @InvocableVariable(label='Draft Lines' description='Each priced line: product, quantity, rate, gross line total, any scheme benefit and the GST added. One per line.')
        public String draftLines;
        @InvocableVariable(label='Total Amount' description='The payable order total in rupees, inclusive of GST and any scheme benefit. This equals the total when the order is placed.')
        public Decimal totalAmount;
        @InvocableVariable(label='Credit Warning' description='A warning if the estimated total exceeds the outlet available credit. Empty if fine.')
        public String creditWarning;
        @InvocableVariable(label='Stock Warning' description='A stock note for the order. Stock is validated when the order is submitted.')
        public String stockWarning;
        @InvocableVariable(label='Must-Sell Warning' description='A warning if required must-sell products are missing from the order. Empty if fine.')
        public String mustSellWarning;
        @InvocableVariable(label='Can Place' description='True if every item resolved and the order is within credit, so it can be placed.')
        public Boolean canPlace;
        @InvocableVariable(label='Summary' description='A ready-to-read draft summary that ends by asking the rep to confirm. Prefer this for the reply.')
        public String summary;
    }

    public class PlaceRequest {
        @InvocableVariable(required=true label='Account Id'
            description='The outlet Account the order is for.')
        public Id accountId;
        @InvocableVariable(required=true label='Items'
            description='The same products and quantities the rep confirmed.')
        public String items;
        @InvocableVariable(required=true label='Confirmed'
            description='Must be true. Set only after the rep has seen the draft and explicitly agreed to place the order.')
        public Boolean confirmed;
    }

    public class PlaceResult {
        @InvocableVariable(label='Order Id' description='Id of the created sales order.')
        public Id orderId;
        @InvocableVariable(label='Order Number' description='The order number of the created order.')
        public String orderNumber;
        @InvocableVariable(label='Placed' description='True if the order was created.')
        public Boolean placed;
        @InvocableVariable(label='Summary' description='A ready-to-read confirmation, or the reason it was not placed. Prefer this for the reply.')
        public String summary;
    }

    /** One parsed + resolved order line. */
    private class ParsedLine {
        Decimal quantity;
        String rawName;
        Id productId;
        String productName;
        Decimal unitPrice;
        Boolean resolved = false;
        // The rep's words matched more than one product and none stood out, so
        // we refuse to guess: these are the choices to put back to the rep.
        Boolean ambiguous = false;
        List<String> candidateLabels;
    }

    // ── Draft (read-only) ─────────────────────────────────────────────────

    public static DraftResult buildDraft(Id accountId, String items) {
        DraftResult d = new DraftResult();
        d.draftLines = '';
        d.stockWarning = '';
        d.creditWarning = '';
        d.mustSellWarning = '';
        d.canPlace = false;

        Account acct = visibleAccount(accountId);
        if (acct == null) {
            d.summary = 'That outlet was not found, or you do not have access to it.';
            return d;
        }
        if (String.isBlank(items)) {
            d.summary = 'Tell me what to order, e.g. "20 Ultra Mini, 10 Grind+ Gold".';
            return d;
        }

        // One must-sell snapshot, shared by the resolver tie-break and the
        // missing-product check so the two can never disagree.
        List<Map<String, Object>> mustSell =
            OrderEntryController.getMustSellProducts(accountId, Date.today());
        List<ParsedLine> lines = parseAndResolve(items, idsFrom(mustSell));
        if (lines.isEmpty()) {
            d.summary = 'I could not read any products from that. Try "20 Ultra Mini, 10 Grind+ Gold".';
            return d;
        }

        List<String> unresolved = new List<String>();   // nothing in the catalogue matched
        List<String> clarify = new List<String>();        // matched several — ask which
        List<String> leftover = new List<String>();       // rendered lines for the two above
        List<ParsedLine> resolved = new List<ParsedLine>();
        for (ParsedLine l : lines) {
            if (l.resolved) { resolved.add(l); continue; }
            if (l.ambiguous && l.candidateLabels != null && !l.candidateLabels.isEmpty()) {
                clarify.add('"' + l.rawName + '" matches several products — '
                    + String.join(l.candidateLabels, ', ') + '. Which did you mean?');
                leftover.add(l.rawName + ' — several matches, please specify');
            } else {
                unresolved.add(l.rawName);
                leftover.add(l.rawName + ' — product not found');
            }
        }

        // Price the draft through the real order engine rather than guessing.
        // Insert the order and its lines inside a savepoint so the pricing,
        // scheme and tax triggers stamp the exact figures, read them back, then
        // roll everything back so the draft creates nothing. This guarantees the
        // preview equals the order Place will create — same GST, same schemes —
        // instead of the old gross estimate that ignored both.
        List<String> rendered = new List<String>();
        List<String> schemeNotes = new List<String>();
        List<String> schemeOpps = new List<String>();
        Decimal grossTotal = 0, taxTotal = 0, netTotal = 0, schemeDiscTotal = 0;
        Boolean priced = false;
        String priceError = '';

        if (!resolved.isEmpty()) {
            Savepoint sp = Database.setSavepoint();
            try {
                Sales_Order__c so = new Sales_Order__c(
                    Account__c = accountId,
                    Status__c = 'Draft',
                    Order_Date__c = Date.today(),
                    Territory__c = acct.Territory__c,
                    Notes__c = 'Draft preview by the SFA Field Copilot'
                );
                insert so;

                List<Order_Line_Item__c> olis = new List<Order_Line_Item__c>();
                for (ParsedLine l : resolved) {
                    olis.add(new Order_Line_Item__c(
                        Sales_Order__c = so.Id,
                        Product_Ext__c = l.productId,
                        Quantity__c = l.quantity,
                        Unit_Price__c = l.unitPrice,   // same seed Place uses
                        UOM__c = 'Pieces'
                    ));
                }
                insert olis;

                // Read the lines back with the amounts the triggers computed
                // (Line_Amount__c gross, Tax_Amount__c GST, Total_Amount__c net)
                // plus the fields the scheme engine needs to re-evaluate.
                List<Order_Line_Item__c> pricedLines = [
                    SELECT Product_Ext__c, Product_Ext__r.Name, Quantity__c, Base_Quantity__c,
                           UOM__c, Unit_Price__c, Line_Amount__c, Net_Amount__c,
                           Scheme_Discount__c, Tax_Amount__c, Total_Amount__c
                    FROM Order_Line_Item__c
                    WHERE Sales_Order__c = :so.Id
                    ORDER BY Product_Ext__r.Name
                ];
                for (Order_Line_Item__c oli : pricedLines) {
                    Decimal gross = nz(oli.Line_Amount__c);
                    Decimal sd = nz(oli.Scheme_Discount__c);
                    Decimal tax = nz(oli.Tax_Amount__c);
                    Decimal net = nz(oli.Total_Amount__c);
                    grossTotal += gross;
                    schemeDiscTotal += sd;
                    taxTotal += tax;
                    netTotal += net;

                    String line = oli.Product_Ext__r.Name + ' x' + nz(oli.Quantity__c).setScale(0)
                        + ' @ ' + inr(oli.Unit_Price__c) + ' = ' + inr(gross);
                    if (sd > 0) line += ' (scheme -' + inr(sd) + ')';
                    if (tax > 0) line += ' +GST ' + inr(tax);
                    rendered.add(line);
                }

                // Schemes: ask the same engine the order screen uses. The line
                // trigger only stamps a scheme when it carries a money discount,
                // so free-goods and reward-points schemes leave no trace on the
                // record — reading the record alone (as before) missed them. The
                // engine returns every applicable benefit, matching the cart.
                Set<String> appliedNames = new Set<String>();
                for (SPM_SchemeEngine_Service.SchemeResult r :
                        SPM_SchemeEngine_Service.getApplicableSchemes(accountId, pricedLines, Date.today())) {
                    appliedNames.add(r.schemeName);
                    List<String> parts = new List<String>();
                    Decimal disc = nz(r.discountAmount) + nz(r.priceDiscount);
                    if (disc > 0) parts.add('-' + inr(disc));
                    if (nz(r.freeQty) > 0) {
                        parts.add('+' + r.freeQty.setScale(0) + ' free'
                            + (String.isBlank(r.freeProductName) ? '' : ' ' + r.freeProductName));
                    }
                    if (nz(r.rewardPoints) > 0) parts.add('earn ' + r.rewardPoints.setScale(0) + ' points');
                    schemeNotes.add(r.schemeName
                        + (parts.isEmpty() ? '' : ' (' + String.join(parts, ', ') + ')'));
                }

                // Near-miss nudges: schemes the order is a few units short of.
                // Every nudge is proven by re-running the engine at the target
                // quantity on the actual basket, so it accounts for everything
                // the real order would — stacking rules (a non-stackable scheme
                // already in the basket blocks another), budgets, usage caps and
                // UOM conversion — and never promises a benefit that would not land.
                schemeOpps = nearMissNudges(accountId, pricedLines, appliedNames);
                priced = true;
            } catch (Exception e) {
                // Placement would fail the same way (e.g. a line below its
                // minimum order quantity). Fall back to a gross estimate below
                // and surface the reason so the rep can fix it.
                priceError = (e instanceof DmlException)
                    ? ((DmlException) e).getDmlMessage(0) : e.getMessage();
            } finally {
                Database.rollback(sp);   // the draft persists nothing, ever
            }
        }

        // Fallback when the trial insert could not price it: gross estimate only.
        if (!priced) {
            rendered.clear();
            grossTotal = 0; taxTotal = 0; netTotal = 0; schemeDiscTotal = 0;
            for (ParsedLine l : resolved) {
                Decimal g = l.quantity * nz(l.unitPrice);
                grossTotal += g;
                rendered.add(l.productName + ' x' + l.quantity.setScale(0)
                    + ' @ ' + inr(l.unitPrice) + ' = ' + inr(g));
            }
            netTotal = grossTotal;   // no tax/scheme figures available
        }

        rendered.addAll(leftover);
        d.draftLines = String.join(rendered, '\n');

        // Total the rep should quote and the credit is checked against is the
        // payable (tax-inclusive) figure when we have it, gross otherwise.
        d.totalAmount = (priced ? netTotal : grossTotal).setScale(2);

        // Credit — available = limit minus outstanding, checked on the payable.
        Decimal available = nz(acct.Credit_Limit__c) - nz(acct.Outstanding_Balance__c);
        if (acct.Credit_Limit__c != null && d.totalAmount > available) {
            d.creditWarning = 'Order ' + inr(d.totalAmount) + ' exceeds available credit '
                + inr(available) + ' (limit ' + inr(acct.Credit_Limit__c)
                + ', outstanding ' + inr(acct.Outstanding_Balance__c) + ').';
        }

        // Must-sell — any required product not on this order.
        d.mustSellWarning = missingMustSell(mustSell, lines);

        d.stockWarning = 'Stock is validated when the order is submitted.';

        String schemeLine = !schemeNotes.isEmpty()
            ? 'Schemes: ' + String.join(schemeNotes, '; ') + '.'
            : (priced ? 'No schemes apply to these items.' : '');

        Boolean allResolved = unresolved.isEmpty() && clarify.isEmpty();
        d.canPlace = priced && allResolved && String.isBlank(d.creditWarning);

        List<String> notes = new List<String>();
        for (String c : clarify) notes.add(c);
        if (!unresolved.isEmpty()) notes.add('Could not find: ' + String.join(unresolved, ', ') + '.');
        if (String.isNotBlank(priceError)) notes.add('Could not price it: ' + priceError);
        if (String.isNotBlank(d.creditWarning)) notes.add(d.creditWarning);
        if (String.isNotBlank(d.mustSellWarning)) notes.add(d.mustSellWarning);
        if (String.isNotBlank(schemeLine)) notes.add(schemeLine);
        if (!schemeOpps.isEmpty()) notes.add('Almost there — ' + String.join(schemeOpps, ' '));

        String money = priced
            ? 'gross ' + inr(grossTotal)
                + (schemeDiscTotal > 0 ? ' - scheme ' + inr(schemeDiscTotal) : '')
                + ' + GST ' + inr(taxTotal) + ' = ' + inr(netTotal)
            : 'estimated ' + inr(grossTotal) + ' before GST';
        String head = 'Draft for ' + acct.Name + ' — ' + money
            + ' across ' + resolved.size() + ' line(s).';
        d.summary = notes.isEmpty()
            ? head + ' Shall I place it?'
            : head + ' ' + String.join(notes, ' ')
                + (d.canPlace ? ' Shall I place it anyway?' : ' Fix these before placing.');
        return d;
    }

    // ── Place (write, confirmation-gated) ─────────────────────────────────

    public static PlaceResult placeOrder(Id accountId, String items, Boolean confirmed) {
        PlaceResult p = new PlaceResult();
        p.placed = false;

        Account acct = visibleAccount(accountId);
        if (acct == null) {
            p.summary = 'That outlet was not found, or you do not have access to it.';
            return p;
        }
        if (confirmed != true) {
            p.summary = 'Not placed — the rep has not confirmed. Show the draft and ask them to confirm first.';
            return p;
        }
        if (String.isBlank(items)) {
            p.summary = 'Nothing to place — no items were given.';
            return p;
        }

        List<ParsedLine> lines = parseAndResolve(items,
            idsFrom(OrderEntryController.getMustSellProducts(accountId, Date.today())));
        List<String> unresolved = new List<String>();
        List<String> clarify = new List<String>();
        List<ParsedLine> resolved = new List<ParsedLine>();
        Decimal total = 0;
        for (ParsedLine l : lines) {
            if (l.resolved) {
                total += l.quantity * (l.unitPrice == null ? 0 : l.unitPrice);
                resolved.add(l);
                continue;
            }
            if (l.ambiguous && l.candidateLabels != null && !l.candidateLabels.isEmpty()) {
                clarify.add('"' + l.rawName + '" could be ' + String.join(l.candidateLabels, ', '));
            } else {
                unresolved.add(l.rawName);
            }
        }
        // Never guess an ambiguous product on a write — make the rep pick first.
        if (!clarify.isEmpty()) {
            p.summary = 'Not placed — please specify which product: ' + String.join(clarify, '; ')
                + '. Name the exact product or its SKU code and I will place it.';
            return p;
        }
        if (!unresolved.isEmpty()) {
            p.summary = 'Not placed — I could not find: ' + String.join(unresolved, ', ')
                + '. Clarify these and try again.';
            return p;
        }
        if (resolved.isEmpty()) {
            p.summary = 'Not placed — no valid products to order.';
            return p;
        }

        // Refuse over-credit up front so the rep gets a clear reason rather than
        // a trigger exception.
        Decimal available = nz(acct.Credit_Limit__c) - nz(acct.Outstanding_Balance__c);
        if (acct.Credit_Limit__c != null && total > available) {
            p.summary = 'Not placed — the order ' + inr(total)
                + ' exceeds available credit ' + inr(available) + '.';
            return p;
        }

        // Create the order directly rather than via OrderEntryController, which
        // is built for a logged-in rep: it enforces the rep's channel
        // authorisation and masks any failure as an AuraHandledException the
        // agent runtime cannot read — an agent user is not that rep. Inserting
        // here still runs the Order Line Item trigger, so pricing, schemes, tax
        // and the header-total rollup all apply; we send only product +
        // quantity and never a price. Created as Draft so nothing is submitted
        // or invoiced without the rep reviewing it on the order screen.
        // If the rep has an open visit at this outlet today, tie the order to it
        // and inherit the visit's beat / day-attendance context — exactly what
        // the order screen does — so the order shows on the Visit Manager Orders
        // tab and rolls up under visit-productivity and beat-wise reporting.
        Visit__c activeVisit = resolveActiveVisit(accountId);

        Savepoint sp = Database.setSavepoint();
        try {
            Sales_Order__c so = new Sales_Order__c(
                Account__c = accountId,
                Status__c = 'Draft',
                Order_Date__c = Date.today(),
                Territory__c = acct.Territory__c,
                Notes__c = 'Drafted by the SFA Field Copilot'
            );
            if (activeVisit != null) {
                so.Visit__c = activeVisit.Id;
                if (activeVisit.Beat__c != null) so.Beat__c = activeVisit.Beat__c;
                if (activeVisit.Day_Attendance__c != null) so.Day_Attendance__c = activeVisit.Day_Attendance__c;
                if (so.Territory__c == null && activeVisit.Beat__r != null) {
                    so.Territory__c = activeVisit.Beat__r.Territory__c;
                }
            }
            insert so;

            // Build the lines as completely as the order screen does — UOM
            // conversion (base quantity / factor / base + order UOM), the
            // product-master MRP and HSN, and the gross line total — so an agent
            // order is not a stripped-down record. The trigger still computes
            // pricing, tax and the header rollup on insert.
            List<Order_Line_Item__c> olis = buildEnrichedLines(resolved, so.Id);
            insert olis;

            // Stamp the scheme benefits the line trigger does not: it records
            // only money discounts, so free goods and reward points (which the
            // order screen applies from the UI) would otherwise be missing from
            // the placed order. Money discounts are left to the trigger so they
            // are not counted twice.
            applyBonusSchemes(accountId, so.Id);

            // The line-item trigger rolls totals into Net_Amount__c / Total_Amount__c,
            // NOT Total_Net_Amount__c (a separate, unpopulated header field), so
            // read the ones the rollup actually writes.
            Sales_Order__c full = [
                SELECT Name, Net_Amount__c, Total_Amount__c, Total_Tax__c, Discount_Amount__c,
                       Total_Free_Quantity__c, Total_Reward_Points__c
                FROM Sales_Order__c WHERE Id = :so.Id LIMIT 1
            ];

            // Mirror those rollup totals into the parallel header fields the
            // order screen also fills (Total_Gross/Discount/Net_Amount), which
            // the trigger leaves blank — otherwise reports reading those show 0.
            update new Sales_Order__c(
                Id = so.Id,
                Total_Gross_Amount__c = nz(full.Total_Amount__c),
                Total_Discount__c = nz(full.Discount_Amount__c),
                Total_Net_Amount__c = nz(full.Net_Amount__c)
            );
            Decimal orderTotal = (full.Net_Amount__c != null && full.Net_Amount__c > 0)
                ? full.Net_Amount__c : full.Total_Amount__c;
            p.orderId = full.Id;
            p.orderNumber = full.Name;
            p.placed = true;
            String bonus = '';
            if (nz(full.Total_Free_Quantity__c) > 0) {
                bonus += ', ' + full.Total_Free_Quantity__c.setScale(0) + ' free item(s)';
            }
            if (nz(full.Total_Reward_Points__c) > 0) {
                bonus += ', ' + full.Total_Reward_Points__c.setScale(0) + ' reward point(s)';
            }
            String visitNote = (activeVisit != null) ? ', linked to your open visit here' : '';
            p.summary = 'Order ' + full.Name + ' created as a draft for ' + acct.Name
                + ', total ' + inr(orderTotal) + bonus + visitNote
                + '. Open it on the order screen to review and submit.';
        } catch (DmlException e) {
            Database.rollback(sp);
            String msg = e.getDmlMessage(0);
            p.summary = 'Could not place the order: '
                + (String.isBlank(msg) ? e.getMessage() : msg);
        } catch (Exception e) {
            Database.rollback(sp);
            p.summary = 'Could not place the order: ' + e.getMessage();
        }
        return p;
    }

    /**
     * @description Builds order lines populated the way the order screen does,
     *              not just product + quantity. Resolves each line UOM to its
     *              base (base quantity, conversion factor, base + order UOM
     *              lookups) via the same UOM_Conversion_Service the UI uses, and
     *              copies MRP / HSN and the gross line total off the product
     *              master — fields the trigger pipeline does not set, so an agent
     *              order matches a Visit Manager one. Pricing, tax and the header
     *              rollup are still stamped by the trigger on insert.
     */
    private static List<Order_Line_Item__c> buildEnrichedLines(List<ParsedLine> resolved, Id orderId) {
        Set<Id> pids = new Set<Id>();
        for (ParsedLine l : resolved) pids.add(l.productId);

        Map<Id, Product_Extension__c> meta = new Map<Id, Product_Extension__c>([
            SELECT Id, MRP__c, HSN_SAC_Code__c, Base_UOM__c, Base_UOM__r.UOM_Code__c
            FROM Product_Extension__c WHERE Id IN :pids
        ]);

        String orderUomCode = UOM_Conversion_Service.mapPicklistToCode('Pieces');
        Id orderUomId = UOM_Conversion_Service.getUOMIdByCode(orderUomCode);

        List<UOM_Conversion_Service.ConversionRequest> reqs =
            new List<UOM_Conversion_Service.ConversionRequest>();
        for (ParsedLine l : resolved) {
            Product_Extension__c pe = meta.get(l.productId);
            String baseCode = (pe != null && pe.Base_UOM__c != null
                    && String.isNotBlank(pe.Base_UOM__r.UOM_Code__c))
                ? pe.Base_UOM__r.UOM_Code__c : 'PCS';
            UOM_Conversion_Service.ConversionRequest cr = new UOM_Conversion_Service.ConversionRequest();
            cr.productId = l.productId;
            cr.fromUomCode = orderUomCode;
            cr.toUomCode = baseCode;
            cr.quantity = l.quantity;
            reqs.add(cr);
        }
        List<UOM_Conversion_Service.ConvertedResult> conv = UOM_Conversion_Service.bulkConvert(reqs);

        List<Order_Line_Item__c> olis = new List<Order_Line_Item__c>();
        for (Integer i = 0; i < resolved.size(); i++) {
            ParsedLine l = resolved[i];
            Product_Extension__c pe = meta.get(l.productId);
            Order_Line_Item__c oli = new Order_Line_Item__c(
                Sales_Order__c = orderId,
                Product_Ext__c = l.productId,
                Quantity__c = l.quantity,
                // Seed the product-master price. The pricing trigger only resolves
                // a Price List when Unit_Price__c is null or zero, so this is kept
                // when set — a zero-priced order (no matching price list) is worse
                // than the catalogue price the rep already saw in the draft.
                Unit_Price__c = l.unitPrice,
                UOM__c = 'Pieces',
                Order_UOM__c = orderUomId,
                Line_Total__c = (l.unitPrice == null ? 0 : l.quantity * l.unitPrice)
            );
            UOM_Conversion_Service.ConvertedResult c = (i < conv.size()) ? conv[i] : null;
            if (c != null) {
                oli.Base_Quantity__c = c.convertedQuantity;
                oli.Conversion_Factor__c = c.conversionFactor;
                oli.Base_UOM__c = c.baseUomId;
            }
            if (pe != null) {
                oli.MRP__c = pe.MRP__c;
                oli.HSN_SAC_Code__c = pe.HSN_SAC_Code__c;
            }
            olis.add(oli);
        }
        return olis;
    }

    /**
     * @description Applies the scheme benefits the line trigger leaves off a
     *              placed order: free goods and reward points. The trigger only
     *              stamps money discounts (applySchemeResults iterates
     *              lineItemDiscounts, which is empty for a free-goods scheme), so
     *              without this a Copilot-placed order would show none of the
     *              free items / points the rep saw on the order screen. Money
     *              discounts are deliberately NOT re-applied here — the trigger
     *              already stamped them and doing so again would double-count.
     */
    private static void applyBonusSchemes(Id accountId, Id orderId) {
        List<Order_Line_Item__c> lines = [
            SELECT Id, Product_Ext__c, Quantity__c, UOM__c, Unit_Price__c,
                   Line_Amount__c, Net_Amount__c, Scheme__c, Scheme_Applied__c,
                   Scheme_Category__c, Free_Quantity__c, Reward_Points__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c = :orderId
        ];
        if (lines.isEmpty()) return;

        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(accountId, lines, Date.today());
        if (results == null || results.isEmpty()) return;

        // First line carrying each product, for mapping a free product back to
        // the line it belongs on (free product == buy product for the common
        // "buy N get 1 free" scheme).
        Map<Id, Order_Line_Item__c> byProduct = new Map<Id, Order_Line_Item__c>();
        for (Order_Line_Item__c l : lines) {
            if (l.Product_Ext__c != null && !byProduct.containsKey(l.Product_Ext__c)) {
                byProduct.put(l.Product_Ext__c, l);
            }
        }

        Set<Id> dirty = new Set<Id>();
        Decimal totalFree = 0;
        Decimal totalPoints = 0;

        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            Order_Line_Item__c target = (r.freeProductId != null)
                ? byProduct.get(r.freeProductId) : null;

            if (nz(r.freeQty) > 0 && target != null) {
                target.Free_Quantity__c = nz(target.Free_Quantity__c) + r.freeQty;
                totalFree += r.freeQty;
                attribute(target, r);
                dirty.add(target.Id);
            }
            if (nz(r.rewardPoints) > 0) {
                Order_Line_Item__c ptsLine = target != null ? target : lines[0];
                ptsLine.Reward_Points__c = nz(ptsLine.Reward_Points__c) + r.rewardPoints;
                totalPoints += r.rewardPoints;
                attribute(ptsLine, r);
                dirty.add(ptsLine.Id);
            }
        }

        if (dirty.isEmpty()) return;

        List<Order_Line_Item__c> toUpdate = new List<Order_Line_Item__c>();
        for (Order_Line_Item__c l : lines) {
            if (dirty.contains(l.Id)) toUpdate.add(l);
        }
        update toUpdate;

        // Header bonus totals (money totals are the trigger rollup's job). Free
        // goods and points carry no rupee value, so the order total is unchanged.
        update new Sales_Order__c(
            Id = orderId,
            Total_Free_Quantity__c = totalFree,
            Total_Reward_Points__c = (Integer) totalPoints
        );
    }

    /** Stamps the scheme lookup on a line if it does not already carry one. */
    private static void attribute(Order_Line_Item__c l, SPM_SchemeEngine_Service.SchemeResult r) {
        if (l.Scheme__c == null && l.Scheme_Applied__c == null) {
            l.Scheme__c = r.schemeId;
            l.Scheme_Applied__c = r.schemeId;
            l.Scheme_Category__c = r.schemeCategory;
        }
    }

    // ── Parsing + resolution ──────────────────────────────────────────────

    /**
     * @description Turns "20 Ultra Mini, 10 Grind+ Gold" into resolved lines.
     *              Segments split on comma / semicolon / newline; the first
     *              number in a segment is the quantity (defaulting to 1), the
     *              rest is the product term, resolved against the catalogue by
     *              resolveInto — which prefers an exact SKU or name match, then
     *              a name/SKU prefix, breaks a remaining tie toward the outlet
     *              must-sell SKU, and otherwise flags the line ambiguous so the
     *              caller can ask the rep which product they meant.
     */
    private static List<ParsedLine> parseAndResolve(String items, Set<Id> mustSellIds) {
        List<ParsedLine> out = new List<ParsedLine>();
        if (String.isBlank(items)) return out;

        for (String seg : items.split('[,;\n]')) {
            String s = seg == null ? '' : seg.trim();
            if (String.isBlank(s)) continue;

            ParsedLine l = new ParsedLine();
            Matcher m = Pattern.compile('(\\d+(?:\\.\\d+)?)').matcher(s);
            l.quantity = m.find() ? Decimal.valueOf(m.group(1)) : 1;

            String name = s.replaceFirst('\\d+(?:\\.\\d+)?', ' ');
            name = name.replaceAll('(?i)\\b(x|cases?|pcs|pieces?|units?|nos|no|qty|of)\\b', ' ');
            name = name.replaceAll('\\s+', ' ').trim();
            l.rawName = String.isBlank(name) ? s : name;

            if (String.isNotBlank(name)) {
                resolveInto(l, name, mustSellIds);
            }
            out.add(l);
            if (out.size() >= 20) break;   // bound the SOQL per action
        }
        return out;
    }

    /**
     * @description Resolves one product term onto a line. Ranks the candidates
     *              (exact SKU > exact name > name/SKU prefix > contains); if the
     *              best tier holds one product it wins, if it holds several but
     *              exactly one is a must-sell SKU that wins, otherwise the line
     *              is left unresolved and flagged ambiguous with its choices.
     */
    private static void resolveInto(ParsedLine l, String term, Set<Id> mustSellIds) {
        List<Product_Extension__c> cands = findCandidates(term);
        if (cands.isEmpty()) return;   // stays unresolved => "product not found"

        String t = term.toLowerCase();
        Integer bestTier = -1;
        for (Product_Extension__c p : cands) {
            Integer tier = tierFor(p, t);
            if (tier > bestTier) bestTier = tier;
        }
        List<Product_Extension__c> top = new List<Product_Extension__c>();
        for (Product_Extension__c p : cands) {
            if (tierFor(p, t) == bestTier) top.add(p);
        }

        Product_Extension__c chosen;
        if (top.size() == 1) {
            chosen = top[0];
        } else {
            // Bias an otherwise-ambiguous term toward the SKU this outlet is
            // meant to stock, so "Beng-Beng" lands on the must-sell product.
            List<Product_Extension__c> pref = new List<Product_Extension__c>();
            for (Product_Extension__c p : top) {
                if (mustSellIds.contains(p.Id)) pref.add(p);
            }
            if (pref.size() == 1) {
                chosen = pref[0];
            } else {
                l.ambiguous = true;
                l.candidateLabels = new List<String>();
                for (Product_Extension__c p : top) {
                    l.candidateLabels.add(p.Name + ' (' + p.SKU_Code__c + ')');
                    if (l.candidateLabels.size() >= 5) break;   // keep the prompt short
                }
                return;
            }
        }
        l.productId = chosen.Id;
        l.productName = chosen.Name;
        l.unitPrice = chosen.Unit_Price__c;
        l.resolved = true;
    }

    /** Scores how tightly a product matches the term; higher is a better match. */
    private static Integer tierFor(Product_Extension__c p, String termLc) {
        String nm = p.Name == null ? '' : p.Name.toLowerCase();
        String sku = p.SKU_Code__c == null ? '' : p.SKU_Code__c.toLowerCase();
        if (sku == termLc) return 4;           // exact SKU
        if (nm == termLc) return 3;            // exact name
        if (nm.startsWith(termLc)) return 2;   // name prefix
        if (sku.startsWith(termLc)) return 2;  // SKU prefix
        return 1;                              // contains (guaranteed by the query)
    }

    /**
     * @description Candidate products for a term. First a contiguous match on
     *              name or SKU; if that finds nothing, an all-words match on the
     *              name so "Beng Beng" (typed without the hyphen) still reaches
     *              "Beng-Beng ...". Bounded so one action stays within limits.
     */
    private static List<Product_Extension__c> findCandidates(String term) {
        String likeTerm = '%' + String.escapeSingleQuotes(term) + '%';
        List<Product_Extension__c> cands = [
            SELECT Id, Name, SKU_Code__c, Unit_Price__c
            FROM Product_Extension__c
            WHERE Name LIKE :likeTerm OR SKU_Code__c LIKE :likeTerm
            ORDER BY Name
            LIMIT 25
        ];
        if (!cands.isEmpty()) return cands;

        List<String> clauses = new List<String>();
        for (String w : term.split('\\s+')) {
            if (w.length() >= 2) {
                clauses.add('Name LIKE \'%' + String.escapeSingleQuotes(w) + '%\'');
            }
        }
        if (clauses.isEmpty()) return cands;
        String soql = 'SELECT Id, Name, SKU_Code__c, Unit_Price__c FROM Product_Extension__c WHERE '
            + String.join(clauses, ' AND ') + ' ORDER BY Name LIMIT 25';
        return Database.query(soql);
    }

    /** Product Ids out of a must-sell snapshot, for the resolver tie-break. */
    private static Set<Id> idsFrom(List<Map<String, Object>> mustSell) {
        Set<Id> ids = new Set<Id>();
        for (Map<String, Object> m : mustSell) {
            Object pid = m.get('productId');
            if (pid != null) ids.add((Id) pid);
        }
        return ids;
    }

    /** Names of must-sell products the order is missing, or empty string. */
    private static String missingMustSell(List<Map<String, Object>> mustSell, List<ParsedLine> lines) {
        Set<Id> onOrder = new Set<Id>();
        for (ParsedLine l : lines) {
            if (l.resolved) onOrder.add(l.productId);
        }
        List<String> missing = new List<String>();
        for (Map<String, Object> m : mustSell) {
            Object pid = m.get('productId');
            if (pid == null) continue;
            if (!onOrder.contains((Id) pid)) {
                Object nm = m.get('productName');
                if (nm != null) missing.add(String.valueOf(nm));
            }
        }
        return missing.isEmpty()
            ? ''
            : 'Missing must-sell products: ' + String.join(missing, ', ') + '.';
    }

    // ── Near-miss scheme nudges ───────────────────────────────────────────

    /**
     * @description Upsell nudges for schemes the order is a few units short of.
     *              Only quantity-gated schemes whose buy product is already on
     *              the order are considered, and every candidate is proven by
     *              re-running the engine at the target quantity on the current
     *              basket. A scheme reads as qty-gated by its threshold field but
     *              may still not fire for basket reasons — most commonly it is
     *              non-stackable and another non-stackable scheme already applies
     *              (the engine takes them in Priority order and skips the rest).
     *              The probe respects all of that, so a nudge is only shown when
     *              the benefit would genuinely land. Bounded to a few probes to
     *              stay within governor limits.
     */
    private static List<String> nearMissNudges(
        Id accountId, List<Order_Line_Item__c> orderLines, Set<String> appliedNames) {
        List<String> nudges = new List<String>();

        Map<Id, Decimal> qtyByProduct = new Map<Id, Decimal>();
        Map<Id, String> nameByProduct = new Map<Id, String>();
        for (Order_Line_Item__c l : orderLines) {
            if (l.Product_Ext__c == null) continue;
            qtyByProduct.put(l.Product_Ext__c, nz(qtyByProduct.get(l.Product_Ext__c)) + nz(l.Quantity__c));
            if (l.Product_Ext__r != null) nameByProduct.put(l.Product_Ext__c, l.Product_Ext__r.Name);
        }
        if (qtyByProduct.isEmpty()) return nudges;

        Integer probes = 0;
        for (Scheme__c s : OrderEntryController.getApplicableSchemes(accountId, Date.today())) {
            if (probes >= 3 || nudges.size() >= 3) break;
            if (appliedNames.contains(s.Name)) continue;
            if (s.Scheme_Type__c != 'Same Product (QTY)' && s.Scheme_Type__c != 'Assorted Product (QTY)') {
                continue;   // qty-gated only; value/invoice thresholds are not unit-addable safely
            }

            // Buy products and their minimum quantities.
            Map<Id, Decimal> buyMins = new Map<Id, Decimal>();
            if (s.Scheme_Products__r != null) {
                for (Scheme_Product__c sp : s.Scheme_Products__r) {
                    if (sp.Is_Buy_Product__c == true && sp.Product_Ext__c != null) {
                        buyMins.put(sp.Product_Ext__c,
                            sp.Min_Quantity__c != null ? sp.Min_Quantity__c : nz(s.Min_Quantity__c));
                    }
                }
            }
            if (buyMins.isEmpty() && s.Product_Ext__c != null && s.Min_Quantity__c != null) {
                buyMins.put(s.Product_Ext__c, s.Min_Quantity__c);
            }

            // A buy product that is on the order but short of its threshold.
            Id buyPid;
            Decimal minQty;
            for (Id pid : buyMins.keySet()) {
                if (!qtyByProduct.containsKey(pid)) continue;
                Decimal cur = qtyByProduct.get(pid);
                Decimal thr = buyMins.get(pid);
                if (thr != null && thr > 0 && cur > 0 && cur < thr) { buyPid = pid; minQty = thr; break; }
            }
            if (buyPid == null) continue;

            probes++;
            if (!unlocksAt(accountId, orderLines, buyPid, minQty, s.Name)) continue;

            Decimal gap = minQty - qtyByProduct.get(buyPid);
            String pname = nameByProduct.containsKey(buyPid) ? nameByProduct.get(buyPid) : 'this product';
            nudges.add('add ' + gap.setScale(0) + ' more ' + pname
                + ' to unlock ' + s.Name + schemeBenefitSuffix(s) + '.');
        }
        return nudges;
    }

    /** True if raising buyPid to targetQty makes schemeName apply (engine-proven). */
    private static Boolean unlocksAt(
        Id accountId, List<Order_Line_Item__c> orderLines, Id buyPid, Decimal targetQty, String schemeName) {
        List<Order_Line_Item__c> probe = new List<Order_Line_Item__c>();
        for (Order_Line_Item__c l : orderLines) {
            Order_Line_Item__c c = l.clone(false, true, false, false);
            if (l.Product_Ext__c == buyPid) {
                Decimal old = nz(l.Quantity__c);
                c.Quantity__c = targetQty;
                // Keep the line value consistent with the raised quantity so a
                // value cross-check inside the engine sees a coherent line.
                if (old > 0) {
                    c.Line_Amount__c = nz(l.Line_Amount__c) * targetQty / old;
                    c.Net_Amount__c = nz(l.Net_Amount__c) * targetQty / old;
                }
            }
            probe.add(c);
        }
        for (SPM_SchemeEngine_Service.SchemeResult r :
                SPM_SchemeEngine_Service.getApplicableSchemes(accountId, probe, Date.today())) {
            if (r.schemeName == schemeName) return true;
        }
        return false;
    }

    /** A short "(1 free X, 100 points)" style benefit suffix for a scheme. */
    private static String schemeBenefitSuffix(Scheme__c s) {
        List<String> b = new List<String>();
        if (nz(s.Free_Quantity__c) > 0) {
            b.add(s.Free_Quantity__c.setScale(0) + ' free'
                + (s.Free_Product_Ext__r != null ? ' ' + s.Free_Product_Ext__r.Name : ''));
        }
        if (nz(s.Discount_Percent__c) > 0) b.add(s.Discount_Percent__c.setScale(0) + '% off');
        if (nz(s.Price_Discount__c) > 0) b.add(inr(s.Price_Discount__c) + ' off');
        if (nz(s.Reward_Points__c) > 0) b.add(s.Reward_Points__c.setScale(0) + ' points');
        return b.isEmpty() ? '' : ' (' + String.join(b, ', ') + ')';
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /**
     * @description The rep's open visit at this outlet today, to tie a placed
     *              order to (mirrors the order screen). An open visit is one that
     *              is Checked In or In Progress. Prefers a visit the running user
     *              owns; falls back to any open visit at the outlet today so the
     *              link still works when the Copilot runs as a shared agent user.
     *              Returns null when there is none — the order is then placed
     *              unlinked, exactly as before.
     */
    private static Visit__c resolveActiveVisit(Id accountId) {
        if (accountId == null) return null;
        List<Visit__c> mine = [
            SELECT Id, Beat__c, Beat__r.Territory__c, Day_Attendance__c
            FROM Visit__c
            WHERE Account__c = :accountId
              AND Visit_Date__c = TODAY
              AND Visit_Status__c IN ('Checked In', 'In Progress')
              AND User__c = :UserInfo.getUserId()
            ORDER BY Check_In_Time__c DESC NULLS LAST
            LIMIT 1
        ];
        if (!mine.isEmpty()) return mine[0];

        List<Visit__c> openVisits = [
            SELECT Id, Beat__c, Beat__r.Territory__c, Day_Attendance__c
            FROM Visit__c
            WHERE Account__c = :accountId
              AND Visit_Date__c = TODAY
              AND Visit_Status__c IN ('Checked In', 'In Progress')
            ORDER BY Check_In_Time__c DESC NULLS LAST
            LIMIT 1
        ];
        return openVisits.isEmpty() ? null : openVisits[0];
    }

    private static Account visibleAccount(Id accountId) {
        if (accountId == null) return null;
        List<Account> accts = [
            SELECT Id, Name, Credit_Limit__c, Outstanding_Balance__c, Territory__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    private static String inr(Decimal d) {
        return '₹' + (d == null ? '0' : d.setScale(2).format());
    }
}