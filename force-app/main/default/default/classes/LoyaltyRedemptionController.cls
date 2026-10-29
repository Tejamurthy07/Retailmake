/**
 * @description LWC-facing controller for redeeming reward points against a
 *              Sales Order. Validates the request, stamps the order with the
 *              redeemed-points qty + loyalty discount (1 point = 1 currency),
 *              and returns the new balance. Idempotent: calling twice on the
 *              same open order just overwrites the redemption.
 *
 * The actual ledger debit (negative Loyalty_Points row) happens later, when
 * the order reaches Approved status — see LoyaltyService.recordWalletMovements.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class LoyaltyRedemptionController {

    // Redemption can only be changed while the order is still being built. Once
    // it is Approved the wallet has been debited, so it (and every later status)
    // is locked.
    private static final Set<String> EDITABLE_STATUSES = new Set<String>{
        'Draft', 'Submitted'
    };

    private static Boolean isLocked(String status) {
        return !EDITABLE_STATUSES.contains(status);
    }

    public class RedemptionPreview {
        @AuraEnabled public Decimal balance;
        @AuraEnabled public Decimal currentlyRedeemed;
        @AuraEnabled public Decimal maxRedeemable;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String orderStatus;
        @AuraEnabled public Boolean canRedeem;
        @AuraEnabled public String message;
    }

    /**
     * @description Returns the redemption state for an order: customer balance,
     *              how much is currently redeemed, and whether redemption is allowed.
     */
    @AuraEnabled(cacheable=false)
    public static RedemptionPreview getPreview(Id orderId) {
        RedemptionPreview p = new RedemptionPreview();
        if (orderId == null) {
            p.canRedeem = false;
            p.message = 'Missing order Id.';
            return p;
        }
        Sales_Order__c o = querySingleOrder(orderId);
        p.accountId = o.Account__c;
        p.orderStatus = o.Status__c;
        p.currentlyRedeemed = o.Reward_Points_Redeemed__c == null ? 0 : o.Reward_Points_Redeemed__c;
        p.balance = o.Account__c == null ? 0 : LoyaltyService.getBalance(o.Account__c);
        // maxRedeemable is just the wallet balance. The current redemption on
        // THIS order is provisional and will debit the wallet on Delivered, so
        // we must not add it back into the headroom — that would let the user
        // overspend their balance.
        p.maxRedeemable = p.balance == null ? 0 : p.balance;

        if (isLocked(o.Status__c)) {
            p.canRedeem = false;
            p.message = 'Redemption is locked once the order is ' + o.Status__c + '.';
        } else if (o.Account__c == null) {
            p.canRedeem = false;
            p.message = 'Order has no Account set.';
        } else if (p.maxRedeemable <= 0) {
            p.canRedeem = false;
            p.message = 'Customer has no points to redeem.';
        } else {
            p.canRedeem = true;
            p.message = null;
        }
        return p;
    }

    /**
     * @description Applies (or overwrites) a points redemption on an open order.
     *              Validates against the customer's wallet balance.
     * @param orderId The Sales_Order__c Id.
     * @param points  Points to redeem (0 clears the redemption).
     * @return Refreshed RedemptionPreview.
     */
    @AuraEnabled
    public static RedemptionPreview applyRedemption(Id orderId, Decimal points) {
        if (orderId == null) {
            throw new AuraHandledException('Missing order Id.');
        }
        if (points == null || points < 0) {
            throw new AuraHandledException('Points must be zero or a positive number.');
        }

        Sales_Order__c o = querySingleOrder(orderId);
        if (o.Account__c == null) {
            throw new AuraHandledException('Order has no Account.');
        }
        if (isLocked(o.Status__c)) {
            throw new AuraHandledException(
                'Cannot change redemption — order is ' + o.Status__c + '.'
            );
        }

        Decimal balance = LoyaltyService.getBalance(o.Account__c);
        if (points > balance) {
            throw new AuraHandledException(
                'Requested ' + points + ' points exceeds wallet balance ' + balance + '.'
            );
        }

        o.Reward_Points_Redeemed__c = points;
        o.Loyalty_Discount__c = points;   // 1 point = 1 currency
        update o;

        return getPreview(orderId);
    }

    private static Sales_Order__c querySingleOrder(Id orderId) {
        return [
            SELECT Id, Account__c, Status__c,
                   Reward_Points_Redeemed__c, Loyalty_Discount__c,
                   Total_Reward_Points__c
            FROM Sales_Order__c
            WHERE Id = :orderId LIMIT 1
        ];
    }
}