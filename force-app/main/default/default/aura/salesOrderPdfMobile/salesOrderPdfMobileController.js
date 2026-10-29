({
    doInit : function(component, event, helper) {
        var recordId = component.get("v.recordId");
        var action = component.get("c.generatePdf");
        action.setParams({ orderId: recordId });
        action.setCallback(this, function(response) {
            var state = response.getState();
            if (state === "SUCCESS") {
                var contentVersionId = response.getReturnValue();
                // Direct download URL — works in mobile browser
                var downloadUrl = '/sfc/servlet.shepherd/version/download/' + contentVersionId;
                window.open(downloadUrl, '_blank');
                $A.get("e.force:closeQuickAction").fire();
            } else {
                var errors = response.getError();
                var msg = 'Failed to generate PDF';
                if (errors && errors[0]) {
                    if (errors[0].message) msg = errors[0].message;
                    else if (errors[0].pageErrors && errors[0].pageErrors[0]) msg = errors[0].pageErrors[0].message;
                }
                $A.get("e.force:showToast").setParams({
                    title: "Error",
                    message: msg,
                    type: "error",
                    duration: 8000
                }).fire();
                $A.get("e.force:closeQuickAction").fire();
            }
        });
        $A.enqueueAction(action);
    }
})