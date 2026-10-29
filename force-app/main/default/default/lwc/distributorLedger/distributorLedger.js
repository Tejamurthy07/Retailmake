import { LightningElement, wire } from 'lwc';
import getLedgerStatement from '@salesforce/apex/DMS_PortalController.getLedgerStatement';
import getAging from '@salesforce/apex/DMS_PortalController.getAging';

const BUCKET_KEYS = ['Current', '1-30', '31-60', '61-90', '90+'];

export default class DistributorLedger extends LightningElement {
    fromDate;
    toDate;
    stmt = { rows: [], openingBalance: 0, closingBalance: 0, totalDebit: 0, totalCredit: 0, accountName: '', fromDate: null, toDate: null };
    loading = false;
    error;
    buckets = [];

    connectedCallback() {
        const now = new Date();
        this.fromDate = this.iso(new Date(now.getFullYear(), now.getMonth(), 1));
        this.toDate = this.iso(now);
        this.generate();
    }

    @wire(getAging)
    wiredAging({ data }) {
        if (data) {
            this.buckets = BUCKET_KEYS.map((k) => ({ label: k, value: this.money(data[k] || 0) }));
        }
    }

    handleFrom(e) { this.fromDate = e.target.value; }
    handleTo(e) { this.toDate = e.target.value; }

    async generate() {
        this.loading = true;
        this.error = undefined;
        try {
            this.stmt = await getLedgerStatement({ fromDate: this.fromDate, toDate: this.toDate });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not generate the ledger.';
        } finally {
            this.loading = false;
        }
    }

    /* ── derived view data ── */
    get rows() {
        return (this.stmt.rows || []).map((r, i) => ({
            key: i,
            dateLabel: this.fmtDate(r.entryDate),
            type: r.type,
            particulars: r.particulars,
            reference: r.reference || '—',
            debitLabel: r.debit ? this.money(r.debit) : '',
            creditLabel: r.credit ? this.money(r.credit) : '',
            balanceLabel: this.balance(r.balance)
        }));
    }
    get hasRows() { return (this.stmt.rows || []).length > 0; }
    get openingLabel() { return this.balance(this.stmt.openingBalance); }
    get closingLabel() { return this.balance(this.stmt.closingBalance); }
    get debitLabel() { return this.money(this.stmt.totalDebit); }
    get creditLabel() { return this.money(this.stmt.totalCredit); }
    get accountName() { return this.stmt.accountName; }
    get periodLabel() { return `${this.fmtDate(this.stmt.fromDate)} — ${this.fmtDate(this.stmt.toDate)}`; }
    get rowCount() { return (this.stmt.rows || []).length; }
    get hasBuckets() { return this.buckets.length > 0; }

    get summary() {
        return [
            { id: 'open', label: 'Opening Balance', value: this.balance(this.stmt.openingBalance), cls: 'dms-lg-kpi__val' },
            { id: 'debit', label: 'Total Debit', value: this.money(this.stmt.totalDebit), cls: 'dms-lg-kpi__val dms-lg-kpi__val_debit' },
            { id: 'credit', label: 'Total Credit', value: this.money(this.stmt.totalCredit), cls: 'dms-lg-kpi__val dms-lg-kpi__val_credit' },
            { id: 'close', label: 'Closing Balance', value: this.balance(this.stmt.closingBalance), cls: 'dms-lg-kpi__val dms-lg-kpi__val_strong' }
        ];
    }

    /* ── CSV export ── */
    get exportDisabled() { return this.loading || !this.hasRows; }
    exportCsv() {
        const lines = [
            [`Statement of Account: ${this.stmt.accountName || ''}`],
            [`Period: ${this.fmtDate(this.stmt.fromDate)} to ${this.fmtDate(this.stmt.toDate)}`],
            [],
            ['Date', 'Particulars', 'Type', 'Reference', 'Debit', 'Credit', 'Balance'],
            ['', 'Opening Balance', '', '', '', '', this.plain(this.stmt.openingBalance)]
        ];
        (this.stmt.rows || []).forEach((r) => {
            lines.push([
                this.fmtDate(r.entryDate), r.particulars || '', r.type || '', r.reference || '',
                r.debit || 0, r.credit || 0, this.plain(r.balance)
            ]);
        });
        lines.push([]);
        lines.push(['', 'Totals', '', '', this.plain(this.stmt.totalDebit), this.plain(this.stmt.totalCredit), '']);
        lines.push(['', 'Closing Balance', '', '', '', '', this.plain(this.stmt.closingBalance)]);

        const csv = lines.map((row) => row.map((c) => this.csvCell(c)).join(',')).join('\r\n');
        const fileName = `Ledger_${(this.stmt.accountName || 'account').replace(/[^a-z0-9]+/gi, '_')}_${this.stmt.fromDate}_to_${this.stmt.toDate}.csv`;
        this.download(csv, fileName);
    }

    // Robust CSV download for Experience Cloud / Locker: prefer a Blob object
    // URL, fall back to a data URI, and always append the anchor to the DOM
    // before clicking (required for the download to fire in most browsers).
    download(csv, fileName) {
        const content = '﻿' + csv; // BOM so Excel reads UTF-8 correctly
        try {
            let href;
            if (typeof URL !== 'undefined' && URL.createObjectURL) {
                const blob = new Blob([content], { type: 'text/csv;charset=utf-8;' });
                href = URL.createObjectURL(blob);
            } else {
                href = 'data:text/csv;charset=utf-8,' + encodeURIComponent(content);
            }
            const a = document.createElement('a');
            a.href = href;
            a.download = fileName;
            a.target = '_self';
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            // Cleanup after the click has been dispatched.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                document.body.removeChild(a);
                if (href.indexOf('blob:') === 0 && URL.revokeObjectURL) { URL.revokeObjectURL(href); }
            }, 0);
        } catch (e) {
            // Last resort: open the CSV in a new tab so it can be saved manually.
            const win = window.open('data:text/csv;charset=utf-8,' + encodeURIComponent(content), '_blank');
            if (!win) { this.error = 'Your browser blocked the download. Please allow pop-ups and try again.'; }
        }
    }
    csvCell(v) {
        const s = v == null ? '' : String(v);
        return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    }

    /* ── helpers ── */
    iso(d) {
        const p = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
    }
    fmtDate(d) {
        if (!d) { return ''; }
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(d));
    }
    money(v) {
        return '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
    // Accounting balance with Dr/Cr suffix (positive = receivable = Dr).
    balance(v) {
        const n = Number(v || 0);
        if (n === 0) { return '₹0.00'; }
        return this.money(Math.abs(n)) + (n > 0 ? ' Dr' : ' Cr');
    }
    plain(v) { return Number(v || 0).toFixed(2); }
}