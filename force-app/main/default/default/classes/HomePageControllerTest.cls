@IsTest
private class HomePageControllerTest {

    @IsTest
    static void testGetHomePageData() {
        Test.startTest();
        HomePageController.HomePageData data = HomePageController.getHomePageData();
        Test.stopTest();

        System.assertNotEquals(null, data, 'HomePageData should not be null');
        System.assertNotEquals(null, data.attendanceStatus, 'Attendance status should have a value');
        System.assertEquals(false, data.isDayStarted, 'Day should not be started without attendance record');
        System.assert(data.todayVisitCount >= 0, 'Visit count should be non-negative');
        System.assert(data.pendingOrderCount >= 0, 'Order count should be non-negative');
        System.assert(data.pendingCollectionCount >= 0, 'Collection count should be non-negative');
        System.assert(data.openTicketCount >= 0, 'Ticket count should be non-negative');
        System.assert(data.pendingLeaveCount >= 0, 'Leave count should be non-negative');
        System.assert(data.pendingExpenseCount >= 0, 'Expense count should be non-negative');
        System.assert(data.lowStockAlertCount >= 0, 'Stock alert count should be non-negative');
        System.assert(data.activeSchemeCount >= 0, 'Scheme count should be non-negative');
        System.assert(data.monthlyOrderValue >= 0, 'Monthly order value should be non-negative');
        System.assert(data.monthlyOrderCount >= 0, 'Monthly order count should be non-negative');
        System.assert(data.monthlyCollectionValue >= 0, 'Monthly collection value should be non-negative');
        System.assert(data.pendingReturnCount >= 0, 'Pending return count should be non-negative');
        System.assert(data.nearExpiryBatchCount >= 0, 'Near expiry batch count should be non-negative');
    }
}