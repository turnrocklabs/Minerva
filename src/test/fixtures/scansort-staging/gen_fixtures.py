#!/usr/bin/env python3
"""Deterministic generator for the scansort functional-regression PDF fixtures.

Re-runnable: produces byte-identical PDFs every run (fixed document metadata,
fixed creation date), so the committed fixtures can be regenerated and diffed.

These PDFs are 100% SYNTHETIC and PII-FREE. Every name, SSN, EIN, account
number, address and dollar amount below is obviously fake. Do NOT replace them
with real data.

Each PDF is designed to be VISUALLY UNAMBIGUOUS to a vision LLM (qwen2.5vl):
a large bold title at the top, a recognisable layout, and clearly labelled
fields — so scansort's vision classifier fires exactly one rule per document.

Usage:
    python3 gen_fixtures.py            # writes the 6 PDFs next to this script

Requires: reportlab  (pip install reportlab)
"""

import os

from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas

# Deterministic metadata — keep these constant so output is byte-stable.
FIXED_DATE = "D:20240115000000+00'00'"
HERE = os.path.dirname(os.path.abspath(__file__))

WIDTH, HEIGHT = letter  # 612 x 792 pt


def _new_canvas(path, title):
    c = canvas.Canvas(path, pagesize=letter)
    c.setTitle(title)
    c.setAuthor("scansort test fixtures")
    c.setSubject("synthetic PII-free test document")
    c.setCreator("gen_fixtures.py")
    c.setProducer("reportlab")
    # Fixed timestamps -> deterministic output.
    c._doc.info.creator = "gen_fixtures.py"
    return c


def _set_fixed_dates(c):
    """Force fixed creation/mod dates so the PDF bytes are reproducible."""
    c._doc.info.invariant = 1


def title(c, text, y=HEIGHT - 0.9 * inch, size=26):
    c.setFont("Helvetica-Bold", size)
    c.drawCentredString(WIDTH / 2, y, text)


def subtitle(c, text, y, size=13):
    c.setFont("Helvetica-Bold", size)
    c.drawCentredString(WIDTH / 2, y, text)


def label_value(c, x, y, label, value, lsize=9, vsize=12):
    c.setFont("Helvetica", lsize)
    c.setFillGray(0.35)
    c.drawString(x, y, label)
    c.setFillGray(0.0)
    c.setFont("Helvetica-Bold", vsize)
    c.drawString(x, y - 16, value)


def box(c, x, y, w, h):
    c.setLineWidth(1)
    c.rect(x, y, w, h, stroke=1, fill=0)


def hline(c, x1, y, x2):
    c.setLineWidth(0.7)
    c.line(x1, y, x2, y)


def finalize(c):
    _set_fixed_dates(c)
    c.showPage()
    c.save()


# ---------------------------------------------------------------------------
# 1. W-2 Wage and Tax Statement
# ---------------------------------------------------------------------------
def gen_w2(path):
    c = _new_canvas(path, "W-2 Wage and Tax Statement 2024")
    title(c, "Form W-2", size=30)
    subtitle(c, "Wage and Tax Statement", HEIGHT - 1.25 * inch, size=16)
    subtitle(c, "Tax Year 2024", HEIGHT - 1.55 * inch, size=12)

    top = HEIGHT - 2.1 * inch
    box(c, 0.75 * inch, top - 1.15 * inch, WIDTH - 1.5 * inch, 1.15 * inch)
    label_value(c, 1.0 * inch, top - 0.25 * inch,
                "Employer name, address, EIN",
                "Acme Test Corporation")
    c.setFont("Helvetica", 10)
    c.drawString(1.0 * inch, top - 0.68 * inch, "500 Sample Plaza, Springfield, ST 00000")
    c.drawString(1.0 * inch, top - 0.92 * inch, "Employer EIN: 00-0000000")

    emp = top - 1.5 * inch
    box(c, 0.75 * inch, emp - 1.05 * inch, WIDTH - 1.5 * inch, 1.05 * inch)
    label_value(c, 1.0 * inch, emp - 0.25 * inch,
                "Employee name", "Jane Q. Sample")
    c.setFont("Helvetica", 10)
    c.drawString(1.0 * inch, emp - 0.68 * inch, "123 Test Street, Springfield, ST 00000")
    c.drawString(1.0 * inch, emp - 0.92 * inch, "Employee SSN: 000-00-0000")

    grid = emp - 1.45 * inch
    rows = [
        ("Box 1  Wages, tips, other compensation", "$90,000.00"),
        ("Box 2  Federal income tax withheld", "$12,000.00"),
        ("Box 3  Social security wages", "$90,000.00"),
        ("Box 4  Social security tax withheld", "$5,580.00"),
        ("Box 5  Medicare wages and tips", "$90,000.00"),
        ("Box 6  Medicare tax withheld", "$1,305.00"),
    ]
    y = grid
    for lbl, val in rows:
        box(c, 0.75 * inch, y - 0.42 * inch, WIDTH - 1.5 * inch, 0.42 * inch)
        c.setFont("Helvetica", 10)
        c.drawString(0.95 * inch, y - 0.27 * inch, lbl)
        c.setFont("Helvetica-Bold", 11)
        c.drawRightString(WIDTH - 0.95 * inch, y - 0.27 * inch, val)
        y -= 0.42 * inch

    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 0.7 * inch,
                        "SYNTHETIC TEST DOCUMENT - NOT A REAL TAX FORM - ALL DATA IS FAKE")
    finalize(c)


# ---------------------------------------------------------------------------
# 2. Electric utility bill
# ---------------------------------------------------------------------------
def gen_utility_bill(path):
    c = _new_canvas(path, "Springfield Power & Light - Electric Bill")
    c.setFillColorRGB(0.05, 0.25, 0.55)
    c.rect(0, HEIGHT - 1.15 * inch, WIDTH, 1.15 * inch, stroke=0, fill=1)
    c.setFillGray(1.0)
    c.setFont("Helvetica-Bold", 24)
    c.drawString(0.75 * inch, HEIGHT - 0.72 * inch, "Springfield Power & Light")
    c.setFont("Helvetica-Bold", 14)
    c.drawString(0.75 * inch, HEIGHT - 1.0 * inch, "ELECTRICITY BILL")
    c.setFillGray(0.0)

    top = HEIGHT - 1.6 * inch
    label_value(c, 0.75 * inch, top, "Service address",
                "123 Test Street, Springfield, ST 00000")
    label_value(c, 4.3 * inch, top, "Account number", "9000-0000-01")
    label_value(c, 0.75 * inch, top - 0.7 * inch, "Billing date", "January 15, 2024")
    label_value(c, 2.8 * inch, top - 0.7 * inch, "Service period",
                "Dec 14 - Jan 13")
    label_value(c, 4.3 * inch, top - 0.7 * inch, "Payment due", "February 5, 2024")

    box(c, 0.75 * inch, top - 2.5 * inch, WIDTH - 1.5 * inch, 1.5 * inch)
    c.setFont("Helvetica-Bold", 12)
    c.drawString(0.95 * inch, top - 1.45 * inch, "Charge summary")
    items = [
        ("Electricity usage   600 kWh", "$72.00"),
        ("Basic service charge", "$15.00"),
        ("State energy tax", "$8.00"),
        ("Previous balance", "$0.00"),
    ]
    y = top - 1.75 * inch
    for lbl, val in items:
        c.setFont("Helvetica", 10)
        c.drawString(0.95 * inch, y, lbl)
        c.drawRightString(WIDTH - 0.95 * inch, y, val)
        y -= 0.22 * inch

    c.setFillColorRGB(0.05, 0.25, 0.55)
    c.rect(0.75 * inch, top - 3.2 * inch, WIDTH - 1.5 * inch, 0.55 * inch,
           stroke=0, fill=1)
    c.setFillGray(1.0)
    c.setFont("Helvetica-Bold", 16)
    c.drawString(0.95 * inch, top - 2.95 * inch, "TOTAL AMOUNT DUE")
    c.drawRightString(WIDTH - 0.95 * inch, top - 2.95 * inch, "$95.00")
    c.setFillGray(0.0)

    c.setFont("Helvetica-Bold", 11)
    c.drawString(0.95 * inch, top - 3.7 * inch, "Meter reading: 600 kWh used this period")
    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 0.7 * inch,
                        "SYNTHETIC TEST DOCUMENT - FAKE UTILITY PROVIDER - ALL DATA IS FAKE")
    finalize(c)


# ---------------------------------------------------------------------------
# 3. Bank statement
# ---------------------------------------------------------------------------
def gen_bank_statement(path):
    c = _new_canvas(path, "First Sample Bank - Account Statement")
    c.setFillColorRGB(0.10, 0.40, 0.20)
    c.rect(0, HEIGHT - 1.1 * inch, WIDTH, 1.1 * inch, stroke=0, fill=1)
    c.setFillGray(1.0)
    c.setFont("Helvetica-Bold", 24)
    c.drawString(0.75 * inch, HEIGHT - 0.65 * inch, "First Sample Bank")
    c.setFont("Helvetica-Bold", 15)
    c.drawString(0.75 * inch, HEIGHT - 0.95 * inch, "MONTHLY ACCOUNT STATEMENT")
    c.setFillGray(0.0)

    top = HEIGHT - 1.55 * inch
    label_value(c, 0.75 * inch, top, "Account holder", "Jane Q. Sample")
    label_value(c, 3.2 * inch, top, "Account number", "Checking ****0000")
    label_value(c, 5.0 * inch, top, "Statement period", "Jan 1 - Jan 31, 2024")

    by = top - 0.9 * inch
    box(c, 0.75 * inch, by - 0.5 * inch, WIDTH - 1.5 * inch, 0.5 * inch)
    c.setFont("Helvetica-Bold", 11)
    c.drawString(0.95 * inch, by - 0.2 * inch, "Beginning balance")
    c.drawRightString(3.8 * inch, by - 0.2 * inch, "$2,000.00")
    c.drawString(4.2 * inch, by - 0.2 * inch, "Ending balance")
    c.drawRightString(WIDTH - 0.95 * inch, by - 0.2 * inch, "$2,350.00")

    ty = by - 0.85 * inch
    c.setFont("Helvetica-Bold", 12)
    c.drawString(0.95 * inch, ty, "Transaction history")
    ty -= 0.1 * inch
    hline(c, 0.95 * inch, ty, WIDTH - 0.95 * inch)
    c.setFont("Helvetica-Bold", 9)
    ty -= 0.2 * inch
    c.drawString(0.95 * inch, ty, "DATE")
    c.drawString(1.9 * inch, ty, "DESCRIPTION")
    c.drawRightString(5.5 * inch, ty, "WITHDRAWAL")
    c.drawRightString(WIDTH - 0.95 * inch, ty, "DEPOSIT")
    txns = [
        ("Jan 03", "Direct deposit - payroll", "", "$1,500.00"),
        ("Jan 08", "Grocery Mart purchase", "$120.00", ""),
        ("Jan 15", "Online transfer out", "$500.00", ""),
        ("Jan 22", "Refund credit", "", "$70.00"),
        ("Jan 28", "Utility payment", "$300.00", ""),
    ]
    c.setFont("Helvetica", 10)
    for d, desc, w, dep in txns:
        ty -= 0.26 * inch
        c.drawString(0.95 * inch, ty, d)
        c.drawString(1.9 * inch, ty, desc)
        if w:
            c.drawRightString(5.5 * inch, ty, w)
        if dep:
            c.drawRightString(WIDTH - 0.95 * inch, ty, dep)
    ty -= 0.1 * inch
    hline(c, 0.95 * inch, ty, WIDTH - 0.95 * inch)

    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 0.7 * inch,
                        "SYNTHETIC TEST DOCUMENT - FAKE BANK - ALL DATA IS FAKE")
    finalize(c)


# ---------------------------------------------------------------------------
# 4. Pay stub / earnings statement
# ---------------------------------------------------------------------------
def gen_pay_stub(path):
    c = _new_canvas(path, "Earnings Statement - Pay Stub")
    title(c, "EARNINGS STATEMENT", size=24)
    subtitle(c, "Pay Stub", HEIGHT - 1.2 * inch, size=14)

    top = HEIGHT - 1.7 * inch
    label_value(c, 0.75 * inch, top, "Employer", "Acme Test Corporation")
    label_value(c, 3.4 * inch, top, "Employee", "Jane Q. Sample")
    label_value(c, 0.75 * inch, top - 0.65 * inch, "Pay period",
                "Jan 1 - Jan 15, 2024")
    label_value(c, 3.4 * inch, top - 0.65 * inch, "Pay date", "January 16, 2024")
    label_value(c, 5.3 * inch, top - 0.65 * inch, "Check number", "000123")

    ey = top - 1.4 * inch
    c.setFont("Helvetica-Bold", 12)
    c.drawString(0.75 * inch, ey, "Earnings")
    hline(c, 0.75 * inch, ey - 0.08 * inch, WIDTH - 0.75 * inch)
    c.setFont("Helvetica-Bold", 9)
    ey -= 0.28 * inch
    c.drawString(0.85 * inch, ey, "DESCRIPTION")
    c.drawRightString(4.0 * inch, ey, "HOURS / RATE")
    c.drawRightString(5.5 * inch, ey, "CURRENT")
    c.drawRightString(WIDTH - 0.85 * inch, ey, "YEAR TO DATE")
    earnings = [
        ("Regular pay", "80.0 @ $43.75", "$3,500.00", "$3,500.00"),
    ]
    c.setFont("Helvetica", 10)
    for d, hr, cur, ytd in earnings:
        ey -= 0.26 * inch
        c.drawString(0.85 * inch, ey, d)
        c.drawRightString(4.0 * inch, ey, hr)
        c.drawRightString(5.5 * inch, ey, cur)
        c.drawRightString(WIDTH - 0.85 * inch, ey, ytd)

    dy = ey - 0.5 * inch
    c.setFont("Helvetica-Bold", 12)
    c.drawString(0.75 * inch, dy, "Deductions")
    hline(c, 0.75 * inch, dy - 0.08 * inch, WIDTH - 0.75 * inch)
    deductions = [
        ("Federal income tax", "$420.00"),
        ("Social security", "$217.00"),
        ("Medicare", "$50.75"),
        ("Health insurance", "$112.25"),
    ]
    c.setFont("Helvetica", 10)
    dyy = dy
    for d, amt in deductions:
        dyy -= 0.26 * inch
        c.drawString(0.85 * inch, dyy, d)
        c.drawRightString(WIDTH - 0.85 * inch, dyy, amt)

    box(c, 0.75 * inch, dyy - 0.7 * inch, WIDTH - 1.5 * inch, 0.5 * inch)
    c.setFont("Helvetica-Bold", 14)
    c.drawString(0.95 * inch, dyy - 0.5 * inch, "NET PAY")
    c.drawRightString(WIDTH - 0.95 * inch, dyy - 0.5 * inch, "$2,700.00")

    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 0.7 * inch,
                        "SYNTHETIC TEST DOCUMENT - FAKE EMPLOYER - ALL DATA IS FAKE")
    finalize(c)


# ---------------------------------------------------------------------------
# 5. Health insurance Explanation of Benefits (EOB)
# ---------------------------------------------------------------------------
def gen_insurance_eob(path):
    c = _new_canvas(path, "Explanation of Benefits - Sample Health Plan")
    c.setFillColorRGB(0.45, 0.10, 0.35)
    c.rect(0, HEIGHT - 1.2 * inch, WIDTH, 1.2 * inch, stroke=0, fill=1)
    c.setFillGray(1.0)
    c.setFont("Helvetica-Bold", 22)
    c.drawString(0.75 * inch, HEIGHT - 0.6 * inch, "Sample Health Plan")
    c.setFont("Helvetica-Bold", 16)
    c.drawString(0.75 * inch, HEIGHT - 0.92 * inch, "EXPLANATION OF BENEFITS")
    c.setFont("Helvetica", 10)
    c.drawString(0.75 * inch, HEIGHT - 1.1 * inch, "THIS IS NOT A BILL")
    c.setFillGray(0.0)

    top = HEIGHT - 1.65 * inch
    label_value(c, 0.75 * inch, top, "Member name", "Jane Q. Sample")
    label_value(c, 3.0 * inch, top, "Member ID", "SHP000000000")
    label_value(c, 5.0 * inch, top, "Claim number", "CLM-0000-0001")
    label_value(c, 0.75 * inch, top - 0.65 * inch, "Provider", "Springfield Test Clinic")
    label_value(c, 3.0 * inch, top - 0.65 * inch, "Date of service", "January 10, 2024")
    label_value(c, 5.0 * inch, top - 0.65 * inch, "Processed date", "January 18, 2024")

    gy = top - 1.4 * inch
    c.setFont("Helvetica-Bold", 11)
    cols = ["SERVICE", "BILLED", "PLAN PAID", "YOU OWE"]
    xs = [0.85 * inch, 3.5 * inch, 4.7 * inch, WIDTH - 0.85 * inch]
    hline(c, 0.75 * inch, gy + 0.12 * inch, WIDTH - 0.75 * inch)
    c.drawString(xs[0], gy, cols[0])
    c.drawRightString(xs[1], gy, cols[1])
    c.drawRightString(xs[2], gy, cols[2])
    c.drawRightString(xs[3], gy, cols[3])
    hline(c, 0.75 * inch, gy - 0.08 * inch, WIDTH - 0.75 * inch)
    rows = [
        ("Office visit", "$200.00", "$160.00", "$40.00"),
        ("Lab work", "$100.00", "$80.00", "$20.00"),
    ]
    c.setFont("Helvetica", 10)
    yy = gy
    for s, b, p, o in rows:
        yy -= 0.3 * inch
        c.drawString(xs[0], yy, s)
        c.drawRightString(xs[1], yy, b)
        c.drawRightString(xs[2], yy, p)
        c.drawRightString(xs[3], yy, o)
    yy -= 0.12 * inch
    hline(c, 0.75 * inch, yy, WIDTH - 0.75 * inch)

    box(c, 0.75 * inch, yy - 0.7 * inch, WIDTH - 1.5 * inch, 0.5 * inch)
    c.setFont("Helvetica-Bold", 13)
    c.drawString(0.95 * inch, yy - 0.5 * inch, "TOTAL PATIENT RESPONSIBILITY")
    c.drawRightString(WIDTH - 0.95 * inch, yy - 0.5 * inch, "$60.00")

    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 0.7 * inch,
                        "SYNTHETIC TEST DOCUMENT - FAKE INSURER - ALL DATA IS FAKE")
    finalize(c)


# ---------------------------------------------------------------------------
# 6. Vehicle registration certificate
# ---------------------------------------------------------------------------
def gen_vehicle_registration(path):
    c = _new_canvas(path, "Certificate of Vehicle Registration")
    # Decorative border to look like a certificate.
    c.setLineWidth(3)
    c.setStrokeColorRGB(0.15, 0.30, 0.15)
    c.rect(0.5 * inch, 0.5 * inch, WIDTH - 1.0 * inch, HEIGHT - 1.0 * inch)
    c.setStrokeGray(0.0)

    c.setFont("Helvetica-Bold", 14)
    c.setFillGray(0.3)
    c.drawCentredString(WIDTH / 2, HEIGHT - 1.1 * inch,
                        "STATE OF SPRINGFIELD - DEPARTMENT OF MOTOR VEHICLES")
    c.setFillGray(0.0)
    title(c, "VEHICLE REGISTRATION", y=HEIGHT - 1.6 * inch, size=26)
    subtitle(c, "Certificate of Registration", HEIGHT - 1.9 * inch, size=13)

    top = HEIGHT - 2.6 * inch
    label_value(c, 1.0 * inch, top, "License plate number", "TEST-000")
    label_value(c, 4.0 * inch, top, "Registration year", "2024")
    label_value(c, 1.0 * inch, top - 0.75 * inch, "Registered owner", "Jane Q. Sample")
    label_value(c, 4.0 * inch, top - 0.75 * inch, "VIN",
                "0SAMPLE00VIN00000")
    label_value(c, 1.0 * inch, top - 1.5 * inch, "Vehicle make / model",
                "Testmobile Sedan")
    label_value(c, 4.0 * inch, top - 1.5 * inch, "Model year", "2020")
    label_value(c, 1.0 * inch, top - 2.25 * inch, "Valid from", "January 1, 2024")
    label_value(c, 4.0 * inch, top - 2.25 * inch, "Expires", "December 31, 2024")
    label_value(c, 1.0 * inch, top - 3.0 * inch, "Registration fee paid", "$85.00")
    label_value(c, 4.0 * inch, top - 3.0 * inch, "Issued", "January 5, 2024")

    c.setFont("Helvetica-Oblique", 9)
    c.setFillGray(0.4)
    c.drawCentredString(WIDTH / 2, 1.0 * inch,
                        "SYNTHETIC TEST DOCUMENT - FAKE DMV - ALL DATA IS FAKE")
    finalize(c)


FIXTURES = [
    ("w2_wage_statement.pdf", gen_w2),
    ("electric_utility_bill.pdf", gen_utility_bill),
    ("bank_statement.pdf", gen_bank_statement),
    ("pay_stub.pdf", gen_pay_stub),
    ("insurance_eob.pdf", gen_insurance_eob),
    ("vehicle_registration.pdf", gen_vehicle_registration),
]


def main():
    for name, fn in FIXTURES:
        path = os.path.join(HERE, name)
        fn(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
