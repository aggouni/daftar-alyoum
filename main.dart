// دفتر اليوم — تطبيق Flutter
// يحتوي على 4 أقسام: الديون، المداخيل، المصروفات، الإرسال + ملخص يومي
// التخزين محلي عبر SharedPreferences، منظم يوميًا مع إمكانية تصفح الأيام السابقة
// + نسخة احتياطية (تصدير/استيراد) لحماية البيانات

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() {
  runApp(const DaftarApp());
}

// ================= الألوان =================
const Color kInk = Color(0xFF1F4B43);
const Color kInkDark = Color(0xFF0F2A24);
const Color kPaper = Color(0xFFEEF2EE);
const Color kCard = Colors.white;
const Color kCardLine = Color(0xFFE3E8E2);
const Color kText = Color(0xFF233330);
const Color kTextDim = Color(0xFF6C7A76);
const Color kGold = Color(0xFFC7973E);
const Color kDebts = Color(0xFF8C6A3B);
const Color kIncome = Color(0xFF2E8F63);
const Color kExpenses = Color(0xFFB4503E);
const Color kSending = Color(0xFF375A78);

const List<String> kWeekdays = ["الأحد","الإثنين","الثلاثاء","الأربعاء","الخميس","الجمعة","السبت"];
const List<String> kMonths = ["جانفي","فيفري","مارس","أفريل","ماي","جوان","جويلية","أوت","سبتمبر","أكتوبر","نوفمبر","ديسمبر"];

// ================= أدوات التاريخ =================
String p2(int n) => n < 10 ? "0$n" : "$n";
String dateKey(DateTime d) => "${d.year}-${p2(d.month)}-${p2(d.day)}";
DateTime keyToDate(String k) {
  final parts = k.split("-").map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}
String todayKey() => dateKey(DateTime.now());

// يوم العمل الافتراضي: يعرض دائمًا يوم أمس، ما عدا يوم السبت فيعرض الخميس (لأن الجمعة عطلة)
String workDayKey() {
  final now = DateTime.now();
  DateTime target;
  if (now.weekday == DateTime.saturday) {
    target = now.subtract(const Duration(days: 2)); // السبت -> الخميس
  } else {
    target = now.subtract(const Duration(days: 1)); // باقي الأيام -> أمس
  }
  return dateKey(target);
}
String fmtMoney(double n) {
  final s = n.round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(",");
    buf.write(s[i]);
  }
  return "${buf.toString()} دج";
}
String uid() => "${DateTime.now().microsecondsSinceEpoch}-${(1000 + (DateTime.now().microsecond % 900))}";

// ================= نموذج البيانات =================
class Entry {
  String id;
  double amount;
  String label; // اسم الزبون أو ملاحظة
  int ts;
  Entry({required this.id, required this.amount, required this.label, required this.ts});
  Map<String, dynamic> toJson() => {"id": id, "amount": amount, "label": label, "ts": ts};
  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j["id"] ?? uid(),
        amount: (j["amount"] as num?)?.toDouble() ?? 0,
        label: j["label"] ?? "",
        ts: j["ts"] ?? 0,
      );
}

class DayData {
  List<Entry> debts = [];
  List<Entry> income = [];
  List<Entry> expenses = [];
  List<Entry> sending = [];

  Map<String, dynamic> toJson() => {
        "debts": debts.map((e) => e.toJson()).toList(),
        "income": income.map((e) => e.toJson()).toList(),
        "expenses": expenses.map((e) => e.toJson()).toList(),
        "sending": sending.map((e) => e.toJson()).toList(),
      };

  static DayData fromJson(Map<String, dynamic> j) {
    final d = DayData();
    d.debts = ((j["debts"] as List?) ?? []).map((e) => Entry.fromJson(Map<String, dynamic>.from(e))).toList();
    d.income = ((j["income"] as List?) ?? []).map((e) => Entry.fromJson(Map<String, dynamic>.from(e))).toList();
    d.expenses = ((j["expenses"] as List?) ?? []).map((e) => Entry.fromJson(Map<String, dynamic>.from(e))).toList();
    d.sending = ((j["sending"] as List?) ?? []).map((e) => Entry.fromJson(Map<String, dynamic>.from(e))).toList();
    return d;
  }

  bool get isEmpty => debts.isEmpty && income.isEmpty && expenses.isEmpty && sending.isEmpty;

  List<Entry> byType(String t) {
    switch (t) {
      case "debts": return debts;
      case "income": return income;
      case "expenses": return expenses;
      case "sending": return sending;
    }
    return [];
  }
}

// ================= إعدادات الأقسام =================
class TabConfig {
  final String label;
  final Color color;
  final bool useName; // true = اسم الزبون، false = ملاحظة
  final String fieldLabel;
  final String placeholder;
  final String empty;
  final String hint;
  final String totalLabel;
  final IconData icon;
  const TabConfig(this.label, this.color, this.useName, this.fieldLabel, this.placeholder, this.empty, this.hint, this.totalLabel, this.icon);
}

const Map<String, TabConfig> kTabs = {
  "debts": TabConfig("الديون", kDebts, true, "اسم الزبون", "مثال: أحمد بن علي", "لا توجد ديون محصلة اليوم", "اضغط على + لتسجيل أول دين تحصلت عليه", "إجمالي الديون المحصلة", Icons.groups_2_outlined),
  "income": TabConfig("مداخيل اليوم", kIncome, false, "ملاحظة", "مثال: بيع بضاعة", "لم تُسجَّل أي مداخيل اليوم", "اضغط على + لإضافة أول مبلغ", "إجمالي المداخيل", Icons.arrow_upward_rounded),
  "sending": TabConfig("الإرسال", kSending, true, "اسم الزبون", "مثال: محل الجملة", "لا توجد إرساليات اليوم", "اضغط على + لإضافة أول إرسالية", "إجمالي الإرسال", Icons.send_rounded),
  "expenses": TabConfig("المصروفات", kExpenses, false, "نوع المصروف", "مثال: وقود، أكل...", "لا توجد مصروفات اليوم", "اضغط على + لإضافة أول مصروف", "إجمالي المصروفات", Icons.arrow_downward_rounded),
};

// ================= التخزين =================
class Store {
  static Future<SharedPreferences> _p() => SharedPreferences.getInstance();

  static Future<List<String>> loadDaysIndex() async {
    final p = await _p();
    final raw = p.getString("days_index");
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveDaysIndex(List<String> idx) async {
    final p = await _p();
    await p.setString("days_index", jsonEncode(idx));
  }

  static Future<DayData> loadDay(String key) async {
    final p = await _p();
    final raw = p.getString("day_$key");
    if (raw == null) return DayData();
    try {
      return DayData.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    } catch (_) {
      return DayData();
    }
  }

  static Future<void> saveDay(String key, DayData data, List<String> daysIndex) async {
    final p = await _p();
    await p.setString("day_$key", jsonEncode(data.toJson()));
    final hasAny = !data.isEmpty;
    final idx = daysIndex.indexOf(key);
    if (hasAny && idx == -1) {
      daysIndex.add(key);
      daysIndex.sort();
      await saveDaysIndex(daysIndex);
    } else if (!hasAny && idx != -1) {
      daysIndex.removeAt(idx);
      await saveDaysIndex(daysIndex);
    }
  }

  static Future<Map<String, dynamic>> exportAll(List<String> daysIndex) async {
    final Map<String, dynamic> days = {};
    for (final k in daysIndex) {
      days[k] = (await loadDay(k)).toJson();
    }
    return {"exportedAt": DateTime.now().toIso8601String(), "daysIndex": daysIndex, "days": days};
  }

  static Future<List<String>> importAll(Map<String, dynamic> backup) async {
    final days = Map<String, dynamic>.from(backup["days"] ?? {});
    final p = await _p();
    for (final entry in days.entries) {
      await p.setString("day_${entry.key}", jsonEncode(entry.value));
    }
    final idx = days.keys.toList()..sort();
    await saveDaysIndex(idx);
    return idx;
  }
}

// ================= التطبيق =================
class DaftarApp extends StatelessWidget {
  const DaftarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "دفتر اليوم",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kPaper,
        colorScheme: ColorScheme.fromSeed(seedColor: kInk),
        textTheme: GoogleFonts.tajawalTextTheme(),
        fontFamily: GoogleFonts.tajawal().fontFamily,
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String currentDate = workDayKey();
  String currentTab = "debts";
  DayData data = DayData();
  List<String> daysIndex = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    daysIndex = await Store.loadDaysIndex();
    data = await Store.loadDay(currentDate);
    setState(() => loading = false);
  }

  Future<void> _goToDate(String key) async {
    final d = await Store.loadDay(key);
    setState(() {
      currentDate = key;
      data = d;
    });
  }

  Future<void> _saveCurrentDay() async {
    await Store.saveDay(currentDate, data, daysIndex);
    setState(() {});
  }

  void _prevDay() {
    final d = keyToDate(currentDate).subtract(const Duration(days: 1));
    _goToDate(dateKey(d));
  }

  void _nextDay() {
    final d = keyToDate(currentDate).add(const Duration(days: 1));
    _goToDate(dateKey(d));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: keyToDate(currentDate),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale("ar"),
    );
    if (picked != null) _goToDate(dateKey(picked));
  }

  Future<void> _deleteEntry(String type, String id) async {
    final list = data.byType(type);
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final removed = list.removeAt(idx);
    await _saveCurrentDay();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text("تم حذف العملية"),
        action: SnackBarAction(
          label: "تراجع",
          textColor: kGold,
          onPressed: () async {
            list.insert(idx.clamp(0, list.length), removed);
            await _saveCurrentDay();
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _openEntrySheet({required String type, Entry? editing}) {
    final cfg = kTabs[type]!;
    final amountCtrl = TextEditingController(text: editing != null ? _trimZero(editing.amount) : "");
    final labelCtrl = TextEditingController(text: editing?.label ?? "");
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 10,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 22,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: kCardLine, borderRadius: BorderRadius.circular(99)))),
              Text((editing != null ? "تعديل — " : "إضافة — ") + cfg.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              const Text("المبلغ", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextDim)),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kCardLine, width: 1.5), borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: amountCtrl,
                      autofocus: true,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                      decoration: const InputDecoration(border: InputBorder.none, hintText: "0"),
                    ),
                  ),
                  const Text("دج", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kTextDim)),
                ]),
              ),
              const SizedBox(height: 14),
              Text(cfg.fieldLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextDim)),
              const SizedBox(height: 6),
              TextField(
                controller: labelCtrl,
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  hintText: cfg.placeholder,
                  filled: true, fillColor: kCard,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine, width: 1.5)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kCardLine, width: 1.5)),
                ),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), side: const BorderSide(color: kCardLine, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("إلغاء", style: TextStyle(color: kTextDim, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kInk, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: () async {
                      final amount = double.tryParse(amountCtrl.text.trim());
                      if (amount == null || amount <= 0) return;
                      if (editing != null) {
                        editing.amount = amount;
                        editing.label = labelCtrl.text.trim();
                      } else {
                        data.byType(type).add(Entry(id: uid(), amount: amount, label: labelCtrl.text.trim(), ts: DateTime.now().millisecondsSinceEpoch));
                      }
                      await _saveCurrentDay();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text("حفظ", style: TextStyle(color: Color(0xFFF3E9D2), fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
              if (editing != null) ...[
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _deleteEntry(type, editing.id);
                    },
                    child: const Text("حذف هذه العملية", style: TextStyle(color: kExpenses, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _trimZero(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _openMonthlyReportSheet() {
    DateTime picked = keyToDate(currentDate);
    showModalBottomSheet(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: kCardLine, borderRadius: BorderRadius.circular(99)))),
                const Text("التقرير الشهري", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text("اختر الشهر الذي تريد إصدار تقريره", style: TextStyle(fontSize: 13, color: kTextDim)),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setSheetState(() => picked = DateTime(picked.year, picked.month - 1, 1)),
                      child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)), child: const Icon(Icons.chevron_right, color: kInk)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)),
                      alignment: Alignment.center,
                      child: Text("${kMonths[picked.month - 1]} ${picked.year}", style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap: () => setSheetState(() => picked = DateTime(picked.year, picked.month + 1, 1)),
                      child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kCardLine)), child: const Icon(Icons.chevron_left, color: kInk)),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: kInk, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _generateMonthlyReport(picked);
                    },
                    icon: const Icon(Icons.picture_as_pdf_outlined, color: Color(0xFFF3E9D2)),
                    label: const Text("إنشاء التقرير", style: TextStyle(color: Color(0xFFF3E9D2), fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _generateMonthlyReport(DateTime month) async {
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: kInk)),
      );
    }
    try {
      final year = month.year;
      final m = month.month;
      final lastDay = DateTime(year, m + 1, 0).day;

      final rows = <List<String>>[];
      double totalIncome = 0, totalExpenses = 0, totalNet = 0;

      for (int day = 1; day <= lastDay; day++) {
        final dKey = dateKey(DateTime(year, m, day));
        final dd = await Store.loadDay(dKey);
        final inc = dd.income.fold(0.0, (s, e) => s + e.amount) + dd.sending.fold(0.0, (s, e) => s + e.amount);
        final exp = dd.expenses.fold(0.0, (s, e) => s + e.amount);
        final net = inc - exp;
        totalIncome += inc;
        totalExpenses += exp;
        totalNet += net;
        rows.add(["$day ${kMonths[m - 1]}", fmtMoney(inc), fmtMoney(exp), fmtMoney(net)]);
      }

      final arabicFont = await PdfGoogleFonts.notoNaskhArabicRegular();
      final arabicBold = await PdfGoogleFonts.notoNaskhArabicBold();
      final doc = pw.Document();

      final pdfInk = PdfColor.fromInt(0xFF1F4B43);
      final pdfIncome = PdfColor.fromInt(0xFF2E8F63);
      final pdfExpenses = PdfColor.fromInt(0xFFB4503E);
      final pdfLine = PdfColor.fromInt(0xFFE3E8E2);

      doc.addPage(
        pw.MultiPage(
          textDirection: pw.TextDirection.rtl,
          theme: pw.ThemeData.withFont(base: arabicFont, bold: arabicBold),
          header: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text("تقرير شهر ${kMonths[m - 1]} $year", style: pw.TextStyle(font: arabicBold, fontSize: 20, color: pdfInk)),
              pw.SizedBox(height: 4),
              pw.Text("دفتر اليوم", style: pw.TextStyle(font: arabicFont, fontSize: 11, color: PdfColors.grey600)),
              pw.SizedBox(height: 14),
              pw.Divider(color: pdfLine),
            ],
          ),
          footer: (ctx) => pw.Container(
            alignment: pw.Alignment.centerLeft,
            margin: const pw.EdgeInsets.only(top: 8),
            child: pw.Text("${ctx.pageNumber} / ${ctx.pagesCount}", style: pw.TextStyle(font: arabicFont, fontSize: 9, color: PdfColors.grey500)),
          ),
          build: (ctx) => [
            pw.Table(
              border: pw.TableBorder.all(color: pdfLine, width: 0.6),
              columnWidths: {
                0: const pw.FlexColumnWidth(2),
                1: const pw.FlexColumnWidth(2.4),
                2: const pw.FlexColumnWidth(2.4),
                3: const pw.FlexColumnWidth(2.4),
              },
              children: [
                pw.TableRow(
                  decoration: pw.BoxDecoration(color: pdfInk),
                  children: [
                    _pdfCell("التاريخ", arabicBold, PdfColors.white, header: true),
                    _pdfCell("المداخيل", arabicBold, PdfColors.white, header: true),
                    _pdfCell("المصروفات", arabicBold, PdfColors.white, header: true),
                    _pdfCell("الصافي", arabicBold, PdfColors.white, header: true),
                  ],
                ),
                ...rows.map((r) => pw.TableRow(children: [
                      _pdfCell(r[0], arabicFont, pdfInk),
                      _pdfCell(r[1], arabicFont, pdfIncome),
                      _pdfCell(r[2], arabicFont, pdfExpenses),
                      _pdfCell(r[3], arabicFont, pdfInk),
                    ])),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: pdfLine), borderRadius: pw.BorderRadius.circular(8)),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
                _pdfTotalRow("إجمالي المداخيل", fmtMoney(totalIncome), arabicFont, arabicBold, pdfIncome),
                pw.SizedBox(height: 6),
                _pdfTotalRow("إجمالي المصروفات", fmtMoney(totalExpenses), arabicFont, arabicBold, pdfExpenses),
                pw.Divider(color: pdfLine, height: 18),
                _pdfTotalRow("الصافي الإجمالي للشهر", fmtMoney(totalNet), arabicBold, arabicBold, pdfInk, big: true),
              ]),
            ),
          ],
        ),
      );

      if (mounted) Navigator.pop(context); // close loading dialog
      await Printing.layoutPdf(onLayout: (format) async => doc.save(), name: "تقرير-${kMonths[m - 1]}-$year.pdf");
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("تعذّر إنشاء التقرير، تأكد من اتصالك بالإنترنت (يلزم لتحميل الخط أول مرة)")));
      }
    }
  }

  pw.Widget _pdfCell(String text, pw.Font font, PdfColor color, {bool header = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: pw.Text(text, style: pw.TextStyle(font: font, fontSize: header ? 11 : 10, color: color), textAlign: pw.TextAlign.center),
    );
  }

  pw.Widget _pdfTotalRow(String label, String value, pw.Font labelFont, pw.Font valueFont, PdfColor color, {bool big = false}) {
    return pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(label, style: pw.TextStyle(font: labelFont, fontSize: big ? 13 : 11, color: PdfColors.grey700)),
      pw.Text(value, style: pw.TextStyle(font: valueFont, fontSize: big ? 15 : 12, color: color)),
    ]);
  }


    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) {
        final sorted = [...daysIndex]..sort((a, b) => b.compareTo(a));
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(left: 20, right: 20, top: 10, bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: kCardLine, borderRadius: BorderRadius.circular(99)))),
                const Text("الأيام السابقة", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                  child: sorted.isEmpty
                      ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text("لا توجد أيام مسجلة بعد", style: TextStyle(color: kTextDim)))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: sorted.length,
                          itemBuilder: (c, i) {
                            final k = sorted[i];
                            final d = keyToDate(k);
                            final isToday = k == workDayKey();
                            final label = "${kWeekdays[d.weekday % 7]}، ${d.day} ${kMonths[d.month - 1]} ${d.year}${isToday ? ' (اليوم)' : ''}";
                            return Container(
                              margin: const EdgeInsets.only(bottom: 9),
                              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                              decoration: BoxDecoration(color: kCard, border: Border.all(color: kCardLine), borderRadius: BorderRadius.circular(14)),
                              child: InkWell(
                                onTap: () {
                                  _goToDate(k);
                                  Navigator.pop(ctx);
                                },
                                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                  Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                                  const Icon(Icons.chevron_left, color: kTextDim),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), side: const BorderSide(color: kCardLine, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      onPressed: () => _exportBackup(),
                      icon: const Icon(Icons.upload_file, size: 17, color: kInk),
                      label: const Text("تصدير نسخة احتياطية", style: TextStyle(fontSize: 12, color: kInk, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), side: const BorderSide(color: kCardLine, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      onPressed: () async {
                        await _importBackup();
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.download_rounded, size: 17, color: kInk),
                      label: const Text("استيراد نسخة احتياطية", style: TextStyle(fontSize: 12, color: kInk, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("إغلاق", style: TextStyle(color: kTextDim, fontWeight: FontWeight.w700))),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _exportBackup() async {
    try {
      final backup = await Store.exportAll(daysIndex);
      final dir = await getTemporaryDirectory();
      final fileName = "نسخة-احتياطية-دفتر-اليوم-${todayKey()}.json";
      final file = File("${dir.path}/$fileName");
      await file.writeAsString(const JsonEncoder.withIndent("  ").convert(backup));
      await Share.shareXFiles([XFile(file.path)], text: "نسخة احتياطية من دفتر اليوم");
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("تعذّر إنشاء النسخة الاحتياطية")));
    }
  }

  Future<void> _importBackup() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPaper,
        title: const Text("استيراد نسخة احتياطية", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("افتح ملف النسخة الاحتياطية، انسخ محتواه بالكامل، ثم الصقه هنا:", style: TextStyle(fontSize: 13, color: kTextDim)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 6,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                hintText: "{ ... }",
                filled: true, fillColor: kCard,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final clip = await Clipboard.getData("text/plain");
                  if (clip?.text != null) controller.text = clip!.text!;
                },
                icon: const Icon(Icons.paste, size: 17),
                label: const Text("لصق من الحافظة"),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("إلغاء", style: TextStyle(color: kTextDim))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kInk),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("استيراد", style: TextStyle(color: Color(0xFFF3E9D2))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final backup = Map<String, dynamic>.from(jsonDecode(controller.text.trim()));
      final newIndex = await Store.importAll(backup);
      daysIndex = newIndex;
      await _goToDate(currentDate);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("تم استرجاع النسخة الاحتياطية بنجاح ✅")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("تعذّر قراءة النص، تأكد أنك لصقت محتوى ملف النسخة الاحتياطية كاملاً")));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(backgroundColor: kPaper, body: Center(child: CircularProgressIndicator(color: kInk)));
    }
    final isToday = currentDate == workDayKey();
    final d = keyToDate(currentDate);

    return Scaffold(
      backgroundColor: kPaper,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(d, isToday),
            Expanded(
              child: currentTab == "summary"
                  ? _buildSummary()
                  : _buildTabList(currentTab),
            ),
          ],
        ),
      ),
      floatingActionButton: currentTab == "summary"
          ? null
          : FloatingActionButton(
              backgroundColor: kInk,
              foregroundColor: const Color(0xFFF3E9D2),
              onPressed: () => _openEntrySheet(type: currentTab),
              child: const Icon(Icons.add, size: 30),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildHeader(DateTime d, bool isToday) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [kInk, kInkDark]),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text("دفتر اليوم", style: GoogleFonts.arefRuqaa(color: const Color(0xFFF3E9D2), fontSize: 26, fontWeight: FontWeight.w700)),
          Row(children: [
            InkWell(
              onTap: _openMonthlyReportSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 38, height: 38,
                margin: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.picture_as_pdf_outlined, color: Color(0xFFF3E9D2), size: 18),
              ),
            ),
            InkWell(
              onTap: _openHistorySheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 38, height: 38,
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.calendar_month_outlined, color: Color(0xFFF3E9D2), size: 19),
              ),
            ),
          ]),
        ]),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center, children: [
          _navArrow(Icons.chevron_right, _prevDay),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: _pickDate,
            child: Transform.rotate(
              angle: -0.1,
              child: Container(
                width: 104, height: 104,
                decoration: BoxDecoration(
                  color: const Color(0xFFFBF9F3),
                  shape: BoxShape.circle,
                  border: Border.all(color: kInk.withOpacity(0.55), width: 2.5),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 18, offset: const Offset(0, 8))],
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text("${d.day}", style: GoogleFonts.arefRuqaa(fontSize: 30, fontWeight: FontWeight.w700, color: kInk, height: 1)),
                  const SizedBox(height: 4),
                  Text(kMonths[d.month - 1], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kInk)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 14),
          _navArrow(Icons.chevron_left, _nextDay),
        ]),
        if (!isToday) ...[
          const SizedBox(height: 12),
          InkWell(
            onTap: () => _goToDate(workDayKey()),
            borderRadius: BorderRadius.circular(99),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(99)),
              child: const Text("العودة إلى اليوم", style: TextStyle(color: Color(0xFFF3E9D2), fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _navArrow(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, color: const Color(0xFFF3E9D2), size: 20),
      ),
    );
  }

  Widget _buildBottomNav() {
    final tabs = ["debts", "income", "sending", "expenses", "summary"];
    final icons = {
      "debts": Icons.groups_2_outlined,
      "income": Icons.arrow_upward_rounded,
      "sending": Icons.send_rounded,
      "expenses": Icons.arrow_downward_rounded,
      "summary": Icons.receipt_long_outlined,
    };
    final labels = {"debts": "الديون", "income": "المداخيل", "sending": "الإرسال", "expenses": "المصروفات", "summary": "الملخص"};
    return Container(
      decoration: BoxDecoration(color: kCard, borderRadius: const BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: const Offset(0, -4))]),
      padding: EdgeInsets.only(top: 8, bottom: MediaQuery.of(context).padding.bottom + 6),
      child: Row(
        children: tabs.map((t) {
          final active = currentTab == t;
          return Expanded(
            child: InkWell(
              onTap: () => setState(() => currentTab = t),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icons[t], size: 21, color: active ? kInk : kTextDim),
                const SizedBox(height: 3),
                Text(labels[t]!, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: active ? kInk : kTextDim)),
              ]),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTabList(String type) {
    final cfg = kTabs[type]!;
    final list = data.byType(type);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 110),
      children: [
        Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: cfg.color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Text(cfg.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 50),
            child: Column(children: [
              const Text("🗒️", style: TextStyle(fontSize: 38)),
              const SizedBox(height: 10),
              Text(cfg.empty, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 6),
              Text(cfg.hint, style: const TextStyle(fontSize: 13, color: kTextDim), textAlign: TextAlign.center),
            ], crossAxisAlignment: CrossAxisAlignment.center),
          )
        else ...[
          ...list.map((e) => _entryCard(type, e, cfg, editable: true)),
          const SizedBox(height: 8),
          _totalBar(cfg.totalLabel, list.fold(0.0, (s, e) => s + e.amount), cfg.color),
        ],
      ],
    );
  }

  Widget _entryCard(String type, Entry e, TabConfig cfg, {required bool editable, VoidCallback? onJump}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: editable ? () => _openEntrySheet(type: type, editing: e) : onJump,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(fmtMoney(e.amount), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cfg.color)),
                const SizedBox(height: 4),
                Text(e.label.isEmpty ? "—" : e.label, style: const TextStyle(fontSize: 13, color: kTextDim, fontWeight: FontWeight.w500)),
              ]),
              if (editable)
                InkWell(
                  onTap: () => _deleteEntry(type, e.id),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: kExpenses.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.delete_outline, size: 18, color: kExpenses),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _totalBar(String label, double total, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kTextDim)),
        Text(fmtMoney(total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: kInk)),
      ]),
    );
  }

  Widget _buildSummary() {
    final incomeTotal = data.income.fold(0.0, (s, e) => s + e.amount);
    final sendingTotal = data.sending.fold(0.0, (s, e) => s + e.amount);
    final expensesTotal = data.expenses.fold(0.0, (s, e) => s + e.amount);
    final net = incomeTotal + sendingTotal - expensesTotal;

    Widget group(String type) {
      final cfg = kTabs[type]!;
      final list = data.byType(type);
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: cfg.color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Text(cfg.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          if (list.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(cfg.empty, style: const TextStyle(color: kTextDim, fontSize: 13)))
          else
            ...list.map((e) => _entryCard(type, e, cfg, editable: false, onJump: () => setState(() => currentTab = type))),
        ]),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        group("income"),
        group("sending"),
        group("expenses"),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine), boxShadow: [BoxShadow(color: kInk.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, 6))]),
          child: Column(children: [
            _totalRow("مجموع المداخيل", incomeTotal, kIncome),
            const Divider(height: 22),
            _totalRow("مجموع الإرسال", sendingTotal, kSending),
            const Divider(height: 22),
            _totalRow("مجموع المصروفات", expensesTotal, kExpenses),
            const SizedBox(height: 14),
            Container(padding: const EdgeInsets.only(top: 14), decoration: const BoxDecoration(border: Border(top: BorderSide(color: kCardLine, width: 2))), child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("صافي الدخل", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                Text(fmtMoney(net), style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: net >= 0 ? kIncome : kExpenses)),
              ],
            )),
          ]),
        ),
      ],
    );
  }

  Widget _totalRow(String label, double value, Color color) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Row(children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: kTextDim)),
      ]),
      Text(fmtMoney(value), style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: color)),
    ]);
  }
}
