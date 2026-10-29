/**
 * @description Centralised GST/tax calculation for DMS invoice generation
 *              (primary & secondary). Wraps MDM_TaxEngine_Service.calculateTaxBulk
 *              and adds the Product_Extension.GST_Rate__c fallback used elsewhere
 *              in the platform, so products without a Tax_Configuration__c still
 *              get taxed. Supports mixed origin/destination states in one call by
 *              grouping lines by state pair (bulk-safe).
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Tax_Service {

    /** One line to be taxed. */
    public class LineTaxInput {
        public Id productId;
        public Decimal amount;
        public String fromState;
        public String toState;

        public LineTaxInput(Id productId, Decimal amount, String fromState, String toState) {
            this.productId = productId;
            this.amount = amount;
            this.fromState = fromState;
            this.toState = toState;
        }
    }

    /** Computed tax for a line. */
    public class LineTax {
        public Decimal taxRate = 0;
        public Decimal cgst = 0;
        public Decimal sgst = 0;
        public Decimal igst = 0;
        public Decimal totalTax = 0;
        public Boolean isInterState = false;
    }

    /**
     * @description Calculates tax for each input line, positionally aligned.
     */
    public static List<LineTax> calculate(List<LineTaxInput> inputs) {
        List<LineTax> output = new List<LineTax>();
        if (inputs == null || inputs.isEmpty()) {
            return output;
        }
        for (Integer i = 0; i < inputs.size(); i++) {
            output.add(new LineTax());
        }

        // Product GST fallback rates.
        Set<Id> productIds = new Set<Id>();
        for (LineTaxInput inp : inputs) {
            if (inp.productId != null) {
                productIds.add(inp.productId);
            }
        }
        Map<Id, Decimal> productGst = new Map<Id, Decimal>();
        for (Product_Extension__c p : [
            SELECT Id, GST_Rate__c FROM Product_Extension__c WHERE Id IN :productIds
        ]) {
            productGst.put(p.Id, p.GST_Rate__c != null ? p.GST_Rate__c : 0);
        }

        // Group line indices by from|to state pair for bulk engine calls.
        Map<String, List<Integer>> indicesByStatePair = new Map<String, List<Integer>>();
        for (Integer i = 0; i < inputs.size(); i++) {
            String key = norm(inputs[i].fromState) + '|' + norm(inputs[i].toState);
            if (!indicesByStatePair.containsKey(key)) {
                indicesByStatePair.put(key, new List<Integer>());
            }
            indicesByStatePair.get(key).add(i);
        }

        for (String pair : indicesByStatePair.keySet()) {
            List<Integer> idxs = indicesByStatePair.get(pair);
            List<Id> pids = new List<Id>();
            List<Decimal> amounts = new List<Decimal>();
            for (Integer idx : idxs) {
                pids.add(inputs[idx].productId);
                amounts.add(inputs[idx].amount);
            }
            String fromState = inputs[idxs[0]].fromState;
            String toState = inputs[idxs[0]].toState;
            Boolean interState = isInterState(fromState, toState);

            List<MDM_TaxEngine_Service.TaxResult> engine =
                MDM_TaxEngine_Service.calculateTaxBulk(pids, fromState, toState, amounts);

            for (Integer j = 0; j < idxs.size(); j++) {
                Integer idx = idxs[j];
                MDM_TaxEngine_Service.TaxResult er = engine[j];
                Decimal amount = amounts[j];
                Decimal rate = (er != null && er.taxRate != null) ? er.taxRate : 0;

                LineTax lt = output[idx];
                lt.isInterState = interState;

                if (rate > 0 && er != null && er.totalTax != null && er.totalTax > 0) {
                    lt.taxRate = rate;
                    lt.cgst = er.cgst;
                    lt.sgst = er.sgst;
                    lt.igst = er.igst;
                    lt.totalTax = er.totalTax;
                } else {
                    // Fallback: product master GST rate.
                    Decimal gst = productGst.containsKey(inputs[idx].productId)
                        ? productGst.get(inputs[idx].productId) : 0;
                    if (gst > 0 && amount != null && amount > 0) {
                        applyRate(lt, amount, gst, interState);
                    }
                }
            }
        }
        return output;
    }

    private static void applyRate(LineTax lt, Decimal amount, Decimal rate, Boolean interState) {
        lt.taxRate = rate;
        if (interState) {
            lt.igst = (amount * rate / 100).setScale(2, RoundingMode.HALF_UP);
        } else {
            Decimal half = rate / 2;
            lt.cgst = (amount * half / 100).setScale(2, RoundingMode.HALF_UP);
            lt.sgst = (amount * half / 100).setScale(2, RoundingMode.HALF_UP);
        }
        lt.totalTax = lt.cgst + lt.sgst + lt.igst;
    }

    private static Boolean isInterState(String fromState, String toState) {
        return String.isNotBlank(fromState) && String.isNotBlank(toState)
            && !fromState.trim().equalsIgnoreCase(toState.trim());
    }

    private static String norm(String s) {
        return String.isBlank(s) ? '' : s.trim().toLowerCase();
    }
}