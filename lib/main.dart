import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart'; // created by `flutterfire configure`

const kA = Color(0xFFFF7A45), kB = Color(0xFFFF3D81);
const kLost = Color(0xFFF59E0B), kFound = Color(0xFF10B981);
const kBg = Color(0xFFFFF7F2);
const cats = {
  'Electronics': '🎧', 'Wallet': '👛', 'Keys': '🔑', 'Books': '📚',
  'ID': '🪪', 'Clothing': '🧥', 'Bottle': '🧴', 'Other': '🎒'
};

// ---------- MODEL ----------
class Item {
  int id, t;
  String type, title, cat, loc, desc, contact;
  String? photo; // base64 image
  bool done, urgent;
  int reward; // in rupees, 0 = no reward
  String college; // campus this post belongs to
  String ownerId, ownerName; // who posted it (cloud user)
  Item({required this.id, required this.t, required this.type, required this.title,
    required this.cat, required this.loc, required this.contact,
    this.desc = '', this.photo, this.done = false, this.urgent = false, this.reward = 0, this.college = '',
    this.ownerId = '', this.ownerName = 'Campus Member'});
  Map<String, dynamic> toJson() => {'id': id, 't': t, 'type': type, 'title': title,
    'cat': cat, 'loc': loc, 'contact': contact, 'desc': desc, 'photo': photo, 'done': done, 'urgent': urgent, 'reward': reward, 'college': college,
    'ownerId': ownerId, 'ownerName': ownerName};
  factory Item.fromJson(Map<String, dynamic> j) => Item(id: j['id'], t: j['t'],
      type: j['type'], title: j['title'], cat: j['cat'], loc: j['loc'],
      contact: j['contact'], desc: j['desc'] ?? '', photo: j['photo'], done: j['done'] ?? false,
      urgent: j['urgent'] ?? false, reward: j['reward'] ?? 0, college: j['college'] ?? '',
      ownerId: j['ownerId'] ?? '', ownerName: j['ownerName'] ?? 'Campus Member');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  String? err;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // every phone gets its own anonymous user id (needs internet the first time)
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } catch (e) {
    err = e.toString(); // error case: no connection / bad setup
  }
  runApp(FindrApp(error: err));
}

class FindrApp extends StatelessWidget {
  final String? error;
  const FindrApp({super.key, this.error});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Findr',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: kB),
      scaffoldBackgroundColor: kBg,
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white, elevation: 10, height: 68, surfaceTintColor: Colors.transparent),
    ),
    home: error != null ? ErrorScreen(error: error!) : const SplashScreen(),
  );
}

// ---------- HOME (state lives here) ----------
class Home extends StatefulWidget {
  final String college;
  const Home({super.key, required this.college});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Item> items = [];
  List<Map<String, dynamic>> notes = [];
  int tab = 0;
  String filter = 'all', q = '', firstName = '';
  String? mapTo; // destination requested from an item
  int mapReq = 0;
  final String uid = FirebaseAuth.instance.currentUser!.uid;
  String userName = 'Campus Member';
  StreamSubscription? _subItems, _subNotes;

  @override
  void initState() {
    super.initState();
    _loadName();
    final db = FirebaseFirestore.instance;
    // live feed for THIS campus: updates instantly when any student posts or edits an item
    _subItems = db.collection('items').where('college', isEqualTo: widget.college).snapshots().listen(
          (s) => setState(() => items = s.docs.map((d) => Item.fromJson(d.data())).toList()),
      onError: (_) => _msg('Connection problem – retrying…'),
    );
    // alerts addressed to this user only
    _subNotes = db.collection('notes').where('toUid', isEqualTo: uid).snapshots().listen((s) {
      final l = s.docs.map((d) => <String, dynamic>{...d.data(), 'docId': d.id}).toList();
      l.sort((a, b) => (b['t'] as int).compareTo(a['t'] as int));
      setState(() => notes = l);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _subItems?.cancel();
    _subNotes?.cancel();
    super.dispose();
  }

  Future<void> _loadName() async {
    final p = await SharedPreferences.getInstance();
    final nm = (p.getString('p_name') ?? '').trim();
    userName = nm.isEmpty ? 'Campus Member' : nm;
    if (mounted) setState(() => firstName = nm.isEmpty ? '' : nm.split(' ').first);
  }

  void _msg(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  String _ago(int t) {
    final m = (DateTime.now().millisecondsSinceEpoch - t) / 60000;
    if (m < 60) return '${m.round().clamp(1, 59)}m ago';
    if (m < 1440) return '${(m / 60).round()}h ago';
    return '${(m / 1440).round()}d ago';
  }

  // Returns false if the report is a duplicate (error case #1)
  bool _add(Item it) {
    final dup = items.any((o) => !o.done && o.type == it.type &&
        o.title.toLowerCase() == it.title.toLowerCase() && o.loc.toLowerCase() == it.loc.toLowerCase());
    if (dup) {
      _msg('This report already exists');
      return false;
    }
    it.college = widget.college;
    it.ownerId = uid;
    it.ownerName = userName;
    final words = it.title.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 2).toList();
    final matches = items.where((o) => !o.done && o.type != it.type && o.cat == it.cat &&
        (words.any((w) => o.title.toLowerCase().contains(w)) || o.loc.toLowerCase() == it.loc.toLowerCase())).toList();
    final db = FirebaseFirestore.instance;
    db.collection('items').doc('${it.id}').set(it.toJson()).catchError((_) {
      _msg('Could not post – check your internet');
    });
    // alert the OTHER user's phone about the possible match
    for (final m in matches) {
      if (m.ownerId.isEmpty) continue;
      db.collection('notes').add({
        'toUid': m.ownerId, 'title': 'Possible match ✨', 't': DateTime.now().millisecondsSinceEpoch, 'read': false,
        'body': '"${it.title}" may match "${m.title}" at ${m.loc}.${m.reward > 0 ? " 💰 ₹${m.reward} reward!" : ""}',
      });
    }
    setState(() => tab = 0);
    _msg('Report posted ✨');
    return true;
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final pages = [
      _feed(),
      SafeArea(bottom: false, child: ReportPage(onSubmit: _add, college: widget.college)),
      SafeArea(bottom: false, child: _alerts()),
      MapScreen(college: widget.college, dest: mapTo, req: mapReq),
      ProfilePage(items: items.where((i) => i.ownerId == uid).toList()),
    ];
    final unread = notes.where((n) => n['read'] == false).length;
    return Scaffold(
      body: IndexedStack(index: tab, sizing: StackFit.expand, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        indicatorColor: kB.withOpacity(.15),
        onDestinationSelected: (i) {
          HapticFeedback.selectionClick();
          setState(() => tab = i);
          _loadName();
        },
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Feed'),
          const NavigationDestination(icon: Icon(Icons.add_circle_rounded), label: 'Report'),
          NavigationDestination(
              icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'),
                  child: const Icon(Icons.notifications_rounded)),
              label: 'Alerts'),
          const NavigationDestination(icon: Icon(Icons.map_rounded), label: 'Map'),
          const NavigationDestination(icon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }

  Widget _stat(String v, String l) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(v, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        Text(l, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    ),
  );

  Widget _feed() {
    final list = items.where((i) {
      if (i.college != widget.college) return false; // only my campus
      final okF = filter == 'all' ? !i.done : filter == 'done' ? i.done : filter == 'reward' ? (i.reward > 0 && !i.done) : (i.type == filter && !i.done);
      final okQ = q.isEmpty || '${i.title} ${i.loc} ${i.cat}'.toLowerCase().contains(q.toLowerCase());
      return okF && okQ;
    }).toList()
      ..sort((a, b) {
        final u = (b.urgent ? 1 : 0) - (a.urgent ? 1 : 0); // urgent posts first
        if (u != 0) return u;
        final r = b.reward - a.reward; // then biggest reward
        if (r != 0) return r;
        return b.t - a.t;
      });
    int c(bool Function(Item) f) => items.where((i) => i.college == widget.college && f(i)).length;
    return Column(children: [
      Container(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 18, 20, 56),
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(firstName.isEmpty ? 'Campus Lost & Found' : 'Hi, $firstName 👋',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Row(children: [
            const Text('Findr 🔎', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CollegeScreen(canGoBack: true))),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(99)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('🎓 ', style: TextStyle(fontSize: 13)),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(widget.college, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 18),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _stat('${c((i) => i.type == 'lost' && !i.done)}', 'Lost'), const SizedBox(width: 10),
            _stat('${c((i) => i.type == 'found' && !i.done)}', 'Found'), const SizedBox(width: 10),
            _stat('${c((i) => i.done)}', 'Reunited'),
          ]),
        ]),
      ),
      Transform.translate(
        offset: const Offset(0, -26),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            elevation: 6, shadowColor: Colors.black12, borderRadius: BorderRadius.circular(18),
            child: TextField(
              onChanged: (v) => setState(() => q = v),
              decoration: InputDecoration(
                hintText: 'Search items, places…', prefixIcon: const Icon(Icons.search),
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              ),
            ),
          ),
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final f in {'all': 'All', 'reward': '💰 Rewards', 'lost': 'Lost', 'found': 'Found', 'done': 'Reunited'}.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.value), selected: filter == f.key,
                selectedColor: kB, labelStyle: TextStyle(color: filter == f.key ? Colors.white : Colors.black87),
                onSelected: (_) => setState(() => filter = f.key),
              ),
            ),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? const Center(child: Text('🕵️\nNothing here yet', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)))
            : ListView.builder(
          padding: const EdgeInsets.all(16), itemCount: list.length,
          itemBuilder: (_, i) => TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Duration(milliseconds: 350 + (i < 6 ? i : 6) * 60),
            curve: Curves.easeOutCubic,
            builder: (_, v, child) =>
                Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 18 * (1 - v)), child: child)),
            child: _card(list[i]),
          ),
        ),
      ),
    ]);
  }

  Widget _thumb(Item i, double s) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: Container(
      width: s, height: s, color: kBg, alignment: Alignment.center,
      child: i.photo != null
          ? Image.memory(base64Decode(i.photo!), width: s, height: s, fit: BoxFit.cover)
          : Text(cats[i.cat] ?? '🎒', style: TextStyle(fontSize: s / 2.4)),
    ),
  );

  Widget _tag(Item i) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
        color: i.done ? Colors.grey : (i.type == 'lost' ? kLost : kFound), borderRadius: BorderRadius.circular(99)),
    child: Text(i.done ? 'REUNITED' : i.type.toUpperCase(),
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
  );

  Widget _urgentChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(99)),
    child: const Text('🚨 URGENT', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
  );

  Widget _rewardChip(Item i) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFFFC837), Color(0xFFFF8008)]),
        borderRadius: BorderRadius.circular(99)),
    child: Text('💰 ₹${i.reward} reward',
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
  );

  Widget _card(Item i) => GestureDetector(
    onTap: () {
      HapticFeedback.selectionClick();
      _detail(i);
    },
    child: Container(
      margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22),
          border: i.urgent && !i.done ? Border.all(color: Colors.red.shade200, width: 1.5) : null,
          boxShadow: const [BoxShadow(color: Color(0x14783228), blurRadius: 20, offset: Offset(0, 8))]),
      child: Row(children: [
        _thumb(i, 74), const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(i.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 4),
          Text('📍 ${i.loc}\n🕒 ${_ago(i.t)}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [_tag(i), if (i.urgent && !i.done) _urgentChip(), if (i.reward > 0 && !i.done) _rewardChip(i)]),
        ])),
      ]),
    ),
  );

  void _detail(Item i) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: _thumb(i, 180)), const SizedBox(height: 14),
          Wrap(spacing: 6, runSpacing: 4, children: [_tag(i), if (i.urgent && !i.done) _urgentChip()]),
          const SizedBox(height: 8),
          Text(i.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(i.desc.isEmpty ? 'No description provided.' : i.desc, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 10),
          Text('📍 ${i.loc}\n📞 ${i.contact}\n👤 ${i.ownerName}\n🕒 ${_ago(i.t)}', style: const TextStyle(height: 1.7)),
          if (i.reward > 0 && !i.done)
            Container(
              width: double.infinity, margin: const EdgeInsets.only(top: 10), padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFFFFF4D6), borderRadius: BorderRadius.circular(14)),
              child: Text('💰 ₹${i.reward} reward offered by the owner\nPaid directly by the owner. Findr doesn’t handle payments.',
                  style: const TextStyle(fontWeight: FontWeight.w600, height: 1.5)),
            ),
          if (widget.college == 'USAR' && matchArea(i.loc) != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14), foregroundColor: kB, side: const BorderSide(color: kB),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                icon: const Icon(Icons.directions_walk_rounded),
                label: Text('Show route to ${matchArea(i.loc)}', overflow: TextOverflow.ellipsis),
                onPressed: () {
                  final a = matchArea(i.loc)!;
                  Navigator.pop(context);
                  setState(() {
                    mapTo = a;
                    mapReq++;
                    tab = 3;
                  });
                },
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (i.ownerId == uid) ...[
            if (!i.done)
              SizedBox(width: double.infinity, child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kB, padding: const EdgeInsets.all(16)),
                onPressed: () {
                  FirebaseFirestore.instance.collection('items').doc('${i.id}').update({'done': true});
                  Navigator.pop(context);
                  _msg('Marked as reunited 🎉');
                },
                child: const Text('Mark as reunited ✓'),
              )),
            TextButton(
              onPressed: () {
                FirebaseFirestore.instance.collection('items').doc('${i.id}').delete();
                Navigator.pop(context);
                _msg('Report deleted');
              },
              child: const Text('Delete report', style: TextStyle(color: Colors.red)),
            ),
          ] else if (!i.done)
            const Text('Use the contact details above to reach the person who posted this.',
                style: TextStyle(color: Colors.black54, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _alerts() => ListView(padding: const EdgeInsets.all(16), children: [
    const SizedBox(height: 30),
    const Text('Alerts', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
    const SizedBox(height: 12),
    if (notes.isEmpty) const Padding(padding: EdgeInsets.only(top: 80),
        child: Center(child: Text('🔕\nNo alerts yet', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)))),
    for (final n in notes)
      Card(
        color: Colors.white, elevation: 0,
        child: ListTile(
          title: Text(n['title'], style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${n['body']} · ${_ago(n['t'])}'),
          trailing: n['read'] == false ? const Icon(Icons.circle, size: 10, color: kB) : null,
          onTap: () => FirebaseFirestore.instance.collection('notes').doc(n['docId']).update({'read': true}),
        ),
      ),
  ]);
}

// ---------- REPORT FORM ----------
class ReportPage extends StatefulWidget {
  final bool Function(Item) onSubmit;
  final String college;
  const ReportPage({super.key, required this.onSubmit, required this.college});
  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final _form = GlobalKey<FormState>();
  final title = TextEditingController(), loc = TextEditingController(),
      desc = TextEditingController(), contact = TextEditingController();
  String type = 'lost', cat = 'Other';
  bool urgent = false;
  final reward = TextEditingController();

  @override
  void initState() {
    super.initState();
    // contact is auto-filled from the one-time login
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => contact.text = p.getString('p_contact') ?? '');
    }).catchError((_) {});
  }
  String? photo;

  Future<void> _pick() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 600, imageQuality: 70);
      if (x != null) {
        final b = await x.readAsBytes();
        setState(() => photo = base64Encode(b));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not load that photo')));
    }
  }

  InputDecoration _d(String l) => InputDecoration(
    labelText: l, filled: true, fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
  );

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Report an item', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      const SizedBox(height: 14),
      SegmentedButton<String>(
        segments: const [ButtonSegment(value: 'lost', label: Text('😟 I lost')), ButtonSegment(value: 'found', label: Text('🙌 I found'))],
        selected: {type}, onSelectionChanged: (s) => setState(() => type = s.first),
      ),
      const SizedBox(height: 14),
      GestureDetector(
        onTap: _pick,
        child: Container(
          height: 150, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
          clipBehavior: Clip.antiAlias, alignment: Alignment.center,
          child: photo == null
              ? const Text('📷  Tap to add a photo', style: TextStyle(color: Colors.black54))
              : Image.memory(base64Decode(photo!), width: double.infinity, fit: BoxFit.cover),
        ),
      ),
      const SizedBox(height: 14),
      TextFormField(controller: title, decoration: _d('Item name'),
          validator: (v) => (v ?? '').trim().length < 3 ? 'Enter at least 3 characters' : null), // error case #2
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        value: cat, decoration: _d('Category'),
        items: cats.keys.map((c) => DropdownMenuItem(value: c, child: Text('${cats[c]} $c'))).toList(),
        onChanged: (v) => setState(() => cat = v!),
      ),
      const SizedBox(height: 14),
      TextFormField(controller: loc, decoration: _d('Location'),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Tell us where it happened' : null),
      const SizedBox(height: 14),
      TextFormField(controller: desc, decoration: _d('Description (optional)'), maxLines: 3),
      const SizedBox(height: 14),
      TextFormField(
        controller: contact, decoration: _d('Email or 10-digit phone'),
        validator: (v) { // error case #3
          final s = (v ?? '').trim();
          final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s) || RegExp(r'^\d{10}$').hasMatch(s.replaceAll(RegExp(r'[\s-]'), ''));
          return ok ? null : 'Enter a valid email or phone number';
        },
      ),
      if (type == 'lost') ...[
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: SwitchListTile(
            value: urgent, activeColor: Colors.red,
            onChanged: (v) => setState(() => urgent = v),
            title: const Text('🚨 Mark as urgent', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Pins your post to the top of the feed'),
          ),
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: reward, keyboardType: TextInputType.number,
          decoration: _d('Reward amount (optional)').copyWith(
              prefixText: '₹ ', helperText: 'Paid directly by you. Findr doesn’t handle payments.'),
          validator: (v) { // error case: invalid reward
            final s = (v ?? '').trim();
            if (s.isEmpty) return null;
            final n = int.tryParse(s);
            if (n == null || n < 1 || n > 50000) return 'Enter an amount between 1 and 50,000';
            return null;
          },
        ),
      ],
      const SizedBox(height: 20),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: kB, padding: const EdgeInsets.all(16)),
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final ok = widget.onSubmit(Item(
              id: DateTime.now().millisecondsSinceEpoch, t: DateTime.now().millisecondsSinceEpoch,
              type: type, title: title.text.trim(), cat: cat, loc: loc.text.trim(),
              desc: desc.text.trim(), contact: contact.text.trim(), photo: photo,
              urgent: type == 'lost' && urgent,
              reward: type == 'lost' ? (int.tryParse(reward.text.trim()) ?? 0) : 0));
          if (ok) { title.clear(); loc.clear(); desc.clear(); reward.clear(); setState(() { photo = null; urgent = false; }); }
        },
        child: const Text('Post report', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    ]),
  );
}

// ---------- PROFILE ----------
const levels = <List<Object>>[
  [0, 'Newcomer', '🌱'],
  [50, 'Helper', '🤝'],
  [150, 'Campus Hero', '🦸'],
  [300, 'Legend', '👑'],
];

class ProfilePage extends StatefulWidget {
  final List<Item> items;
  const ProfilePage({super.key, required this.items});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String name = 'Campus Member', dept = 'Add your department';

  @override
  void initState() {
    super.initState();
    _load();
  }

  // User data is stored on the device with shared_preferences
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      name = p.getString('p_name') ?? name;
      dept = p.getString('p_dept') ?? dept;
    });
  }

  Future<void> _edit() async {
    final n = TextEditingController(text: name == 'Campus Member' ? '' : name);
    final d = TextEditingController(text: dept == 'Add your department' ? '' : dept);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, maxLength: 30, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: d, maxLength: 40, decoration: const InputDecoration(labelText: 'Department / Year')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (n.text.trim().length < 2) {
      // error case: name too short
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name must be at least 2 characters')));
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('p_name', n.text.trim());
    await p.setString('p_dept', d.text.trim().isEmpty ? 'Add your department' : d.text.trim());
    _load();
  }

  Widget _stars(double r) => Row(mainAxisSize: MainAxisSize.min, children: [
    for (int i = 0; i < 5; i++)
      Icon(r - i >= 1 ? Icons.star_rounded : (r - i >= .5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
          color: Colors.amber, size: 26),
  ]);

  Widget _box(String v, String l, String e) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(color: Color(0x14783228), blurRadius: 16, offset: Offset(0, 6))]),
      child: Column(children: [
        Text(e, style: const TextStyle(fontSize: 22)),
        Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Text(l, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final it = widget.items;
    final foundPosted = it.where((i) => i.type == 'found').length;
    final returned = it.where((i) => i.type == 'found' && i.done).length;
    final recovered = it.where((i) => i.type == 'lost' && i.done).length;
    final pts = foundPosted * 10 + returned * 50 + recovered * 5;
    // rating out of 5: how many of the items you found were actually returned
    final rate = foundPosted == 0 ? 0.0 : (returned / foundPosted) * 4 + returned.clamp(0, 5) / 5;

    final lv = levels.lastWhere((l) => pts >= (l[0] as int));
    final next = levels.firstWhere((l) => (l[0] as int) > pts, orElse: () => <Object>[]);
    final progress = next.isEmpty ? 1.0 : (pts - (lv[0] as int)) / ((next[0] as int) - (lv[0] as int));

    final badges = <String, bool>{
      '🔍 First Find': foundPosted >= 1,
      '🎉 First Return': returned >= 1,
      '🛡️ Trusted Helper': returned >= 3,
      '🦅 Eagle Eye': foundPosted >= 5,
    };

    return ListView(padding: EdgeInsets.zero, children: [
      Container(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 20, 20, 28),
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
        ),
        child: Column(children: [
          Align(alignment: Alignment.centerRight,
              child: IconButton(onPressed: _edit, icon: const Icon(Icons.edit_rounded, color: Colors.white))),
          CircleAvatar(radius: 38, backgroundColor: Colors.white24,
              child: Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.w800))),
          const SizedBox(height: 10),
          Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          Text(dept, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 12),
          _stars(rate),
          Text(foundPosted == 0 ? 'Post a found item to earn a rating' : '${rate.toStringAsFixed(1)} helper rating',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${lv[2]} ${lv[1]} · $pts pts', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 10),
              ClipRRect(borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 10, color: kB, backgroundColor: kBg)),
              const SizedBox(height: 6),
              Text(next.isEmpty ? 'Top level reached 🎉' : '${(next[0] as int) - pts} pts to ${next[1]}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            _box('$foundPosted', 'Items found', '🔍'), const SizedBox(width: 10),
            _box('$returned', 'Returned', '🤝'), const SizedBox(width: 10),
            _box('$recovered', 'Recovered', '🎒'),
          ]),
          const SizedBox(height: 20),
          const Text('Badges', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in badges.entries)
              Chip(label: Text(b.key), backgroundColor: b.value ? kFound.withOpacity(.18) : Colors.black12,
                  labelStyle: TextStyle(color: b.value ? Colors.black87 : Colors.black38, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 20),
          const Text('How points work', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('+10 for posting a found item\n+50 when a found item is marked reunited\n+5 when your lost item is recovered',
              style: TextStyle(color: Colors.black54, height: 1.7)),
          const SizedBox(height: 28),
          const Center(
            child: Text('Made with 💛 by Anwesh for GDG USAR',
                style: TextStyle(color: Colors.black45, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    ]);
  }
}

// ---------- LOGO ----------
class LogoPainter extends CustomPainter {
  final Color color;
  LogoPainter(this.color);
  @override
  void paint(Canvas c, Size s) {
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * .09
      ..strokeCap = StrokeCap.round;
    final ctr = Offset(s.width * .44, s.height * .44);
    c.drawCircle(ctr, s.width * .22, ring); // magnifier lens
    c.drawCircle(ctr, s.width * .07, Paint()..color = color); // the "found" dot
    ring.strokeWidth = s.width * .12;
    c.drawLine(Offset(s.width * .61, s.height * .61), Offset(s.width * .77, s.height * .77), ring); // handle
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class FindrLogo extends StatelessWidget {
  final double size;
  final bool inverted; // white tile for use on the gradient splash
  const FindrLogo({super.key, this.size = 80, this.inverted = false});
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      gradient: inverted ? null : const LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
      color: inverted ? Colors.white : null,
      borderRadius: BorderRadius.circular(size * .3),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(.18), blurRadius: size * .3, offset: Offset(0, size * .12))],
    ),
    child: CustomPaint(painter: LogoPainter(inverted ? kB : Colors.white)),
  );
}

// ---------- SPLASH ----------
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    String? college, name;
    try {
      final p = await SharedPreferences.getInstance();
      college = p.getString('college');
      name = p.getString('p_name');
    } catch (_) {} // if storage fails, just ask for the college again
    await Future.delayed(const Duration(milliseconds: 2400));
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, __, ___) => name == null
            ? const LoginScreen()
            : college == null ? const CollegeScreen() : Home(college: college),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      width: double.infinity, height: double.infinity,
      decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight)),
      child: SafeArea(
        child: Column(children: [
          const Spacer(flex: 5),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1), duration: const Duration(milliseconds: 1000), curve: Curves.easeOutBack,
            builder: (_, v, child) => Opacity(opacity: v.clamp(0.0, 1.0), child: Transform.scale(scale: v, child: child)),
            child: Column(children: const [
              FindrLogo(size: 110, inverted: true),
              SizedBox(height: 22),
              Text('Findr', style: TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w800, letterSpacing: -1)),
              SizedBox(height: 4),
              Text('Lost it? Find it.', style: TextStyle(color: Colors.white70, fontSize: 15)),
            ]),
          ),
          const Spacer(flex: 4),
          const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
          const SizedBox(height: 18),
          const Text('Made with 💛 by Anwesh for GDG USAR', style: TextStyle(color: Colors.white60, fontSize: 11)),
          const SizedBox(height: 16),
        ]),
      ),
    ),
  );
}

// ---------- COLLEGE PICKER ----------
class CollegeScreen extends StatefulWidget {
  final bool canGoBack;
  const CollegeScreen({super.key, this.canGoBack = false});
  @override
  State<CollegeScreen> createState() => _CollegeScreenState();
}

class _CollegeScreenState extends State<CollegeScreen> {
  String q = '';
  static const colleges = [
    ['USAR', 'University School of Automation & Robotics, GGSIPU', '🤖'],
    ['IIT Delhi', 'Indian Institute of Technology', '🏛️'],
    ['NIT Delhi', 'National Institute of Technology', '🎓'],
    ['IIIT Delhi', 'Indraprastha Institute of Information Technology', '💻'],
    ['DTU', 'Delhi Technological University', '⚙️'],
    ['NSUT', 'Netaji Subhas University of Technology', '🧪'],
    ['Delhi University', 'University of Delhi', '📚'],
  ];

  Future<void> _pick(String c) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('college', c);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not remember your choice, continuing anyway')));
      }
    }
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => Home(college: c)), (r) => false);
  }

  Future<void> _other() async {
    final ctrl = TextEditingController();
    String? err;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Your college'),
          content: TextField(
            controller: ctrl, maxLength: 40, autofocus: true,
            decoration: InputDecoration(hintText: 'e.g. Amity University', errorText: err),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final t = ctrl.text.trim();
                if (t.length < 3) {
                  setD(() => err = 'Enter at least 3 characters'); // error case
                  return;
                }
                Navigator.pop(ctx, t);
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (name != null) _pick(name);
  }

  Widget _tile(String title, String sub, String emoji, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x14783228), blurRadius: 18, offset: Offset(0, 6))]),
      child: Row(children: [
        Container(width: 48, height: 48, alignment: Alignment.center,
            decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(14)),
            child: Text(emoji, style: const TextStyle(fontSize: 24))),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          Text(sub, style: const TextStyle(color: Colors.black54, fontSize: 12)),
        ])),
        const Icon(Icons.chevron_right_rounded, color: Colors.black38),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = colleges.where((c) => '${c[0]} ${c[1]}'.toLowerCase().contains(q.toLowerCase())).toList();
    return Scaffold(
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 14, 20, 52),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.canGoBack)
              IconButton(padding: EdgeInsets.zero, onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white))
            else
              const FindrLogo(size: 46, inverted: true),
            const SizedBox(height: 16),
            const Text('Where do you study?', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('We’ll show lost & found items from your campus.', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
        Transform.translate(
          offset: const Offset(0, -26),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Material(
              elevation: 6, shadowColor: Colors.black12, borderRadius: BorderRadius.circular(18),
              child: TextField(
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                  hintText: 'Search your college…', prefixIcon: const Icon(Icons.search),
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            for (final c in list) _tile(c[0], c[1], c[2], () => _pick(c[0])),
            _tile('Other college', 'Type your college name', '✏️', _other),
          ]),
        ),
      ]),
    );
  }
}

// ---------- IN-APP USAR CAMPUS MAP ----------
// Positions are in metres on a simple plan (x = east, y = north).
// They are PLACEHOLDERS: measure the real campus and edit the numbers below.
class Spot {
  final String name, emoji, hint;
  final Offset pos;
  final List<String> keys; // words in a typed location that map to this spot
  const Spot(this.name, this.emoji, this.hint, this.pos, [this.keys = const []]);
}

const kSpots = <Spot>[
  Spot('Main Gate', '🚪', 'Campus entrance', Offset(150, 28), ['gate', 'entrance']),
  Spot('Parking', '🅿️', 'Multilevel car parking', Offset(55, 40), ['parking']),
  Spot('Canteen', '🍜', 'Food and snacks', Offset(215, 55), ['canteen', 'food', 'mess']),
  Spot('Central Library', '📚', 'Reading halls', Offset(150, 108), ['library']),
  Spot('Academic Block', '🏫', 'Lecture theatres', Offset(75, 102), ['academic', 'classroom', 'lecture']),
  Spot('Computer Centre', '💻', 'Computer labs', Offset(55, 160), ['computer', 'lab']),
  Spot('Admin Block', '🏢', 'Administrative offices', Offset(230, 112), ['admin']),
  Spot('Auditorium', '🎭', 'Events and seminars', Offset(150, 165), ['auditorium']),
  Spot('Amphitheatre', '🎤', 'Open-air stage', Offset(215, 185), ['amphitheatre', 'amphitheater']),
  Spot('Boys Hostel', '🛏️', 'Hostel for boys', Offset(75, 212), ['boys hostel']),
  Spot('Girls Hostel', '🛏️', 'Hostel for girls', Offset(255, 212), ['girls hostel']),
  Spot('Sports Block', '🏀', 'Playground and sports hall', Offset(285, 72), ['sports', 'ground', 'playground']),
];

// walking junctions that are not named places
const kJunctions = <String, Offset>{'plaza': Offset(150, 58), 'spine': Offset(150, 135)};

// walkable paths between spots / junctions
const kLinks = <List<String>>[
  ['Main Gate', 'plaza'], ['Main Gate', 'Parking'], ['Parking', 'Academic Block'],
  ['plaza', 'Canteen'], ['plaza', 'Academic Block'], ['plaza', 'Central Library'],
  ['Canteen', 'Sports Block'], ['Canteen', 'Admin Block'], ['Admin Block', 'Sports Block'],
  ['Central Library', 'spine'], ['spine', 'Academic Block'], ['spine', 'Admin Block'],
  ['spine', 'Auditorium'], ['Academic Block', 'Computer Centre'], ['Auditorium', 'Amphitheatre'],
  ['Auditorium', 'Boys Hostel'], ['Amphitheatre', 'Girls Hostel'], ['Computer Centre', 'Boys Hostel'],
];

final Map<String, Offset> kPos = {for (final s in kSpots) s.name: s.pos, ...kJunctions};

String? matchArea(String loc) {
  final l = loc.toLowerCase();
  for (final s in kSpots) {
    if (l.contains(s.name.toLowerCase()) || s.keys.any((k) => l.contains(k))) return s.name;
  }
  return null;
}

// shortest walking route (Dijkstra)
List<String>? findRoute(String from, String to) {
  final dist = <String, double>{for (final id in kPos.keys) id: double.infinity};
  final prev = <String, String>{};
  final todo = <String>{...kPos.keys};
  dist[from] = 0;
  while (todo.isNotEmpty) {
    final u = todo.reduce((a, b) => dist[a]! <= dist[b]! ? a : b);
    if (dist[u] == double.infinity) break;
    todo.remove(u);
    if (u == to) break;
    for (final l in kLinks) {
      String? v;
      if (l[0] == u) {
        v = l[1];
      } else if (l[1] == u) {
        v = l[0];
      }
      if (v == null || !todo.contains(v)) continue;
      final nd = dist[u]! + (kPos[u]! - kPos[v]!).distance;
      if (nd < dist[v]!) {
        dist[v] = nd;
        prev[v] = u;
      }
    }
  }
  if (from != to && !prev.containsKey(to)) return null;
  final path = <String>[to];
  while (path.first != from) {
    path.insert(0, prev[path.first]!);
  }
  return path;
}

class RouteStep {
  final String text;
  final IconData icon;
  final int metres;
  RouteStep(this.text, this.icon, this.metres);
}

class _Leg {
  double brg, len;
  final List<String> pass = [];
  _Leg(this.brg, this.len);
}

String _compass(double b) =>
    const ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'][((b + 22.5) % 360 ~/ 45)];

// turns a path into "turn right and walk 25 m" style steps
List<RouteStep> buildSteps(List<String> path) {
  double brg(Offset a, Offset b) => (math.atan2(b.dx - a.dx, b.dy - a.dy) * 180 / math.pi + 360) % 360;
  final legs = <_Leg>[];
  for (int i = 0; i < path.length - 1; i++) {
    final a = kPos[path[i]]!, b = kPos[path[i + 1]]!;
    final bg = brg(a, b), len = (b - a).distance;
    if (legs.isNotEmpty && (((bg - legs.last.brg + 540) % 360) - 180).abs() < 20) {
      legs.last.len += len; // keep going straight
    } else {
      legs.add(_Leg(bg, len));
    }
    if (i + 1 < path.length - 1 && kSpots.any((s) => s.name == path[i + 1])) legs.last.pass.add(path[i + 1]);
  }
  final steps = <RouteStep>[];
  for (int k = 0; k < legs.length; k++) {
    final l = legs[k];
    final m = math.max(5, (l.len / 5).round() * 5);
    String text;
    IconData icon;
    if (k == 0) {
      text = 'Head ${_compass(l.brg)} for $m m';
      icon = Icons.straight_rounded;
    } else {
      final turn = ((l.brg - legs[k - 1].brg + 540) % 360) - 180;
      final right = turn > 0, a = turn.abs();
      final side = right ? 'right' : 'left';
      if (a < 45) {
        text = 'Bear slightly $side';
        icon = right ? Icons.turn_slight_right_rounded : Icons.turn_slight_left_rounded;
      } else if (a < 120) {
        text = 'Turn $side';
        icon = right ? Icons.turn_right_rounded : Icons.turn_left_rounded;
      } else {
        text = 'Turn sharply $side';
        icon = right ? Icons.turn_sharp_right_rounded : Icons.turn_sharp_left_rounded;
      }
      text += ' and walk $m m';
    }
    if (l.pass.isNotEmpty) text += ' · pass ${l.pass.join(', ')}';
    steps.add(RouteStep(text, icon, m));
  }
  steps.add(RouteStep('You’ve arrived at ${path.last} 🎉', Icons.flag_rounded, 0));
  return steps;
}

class CampusPainter extends CustomPainter {
  final List<String> route;
  final String? from, to;
  CampusPainter(this.route, this.from, this.to);
  static const w = 320.0, h = 240.0;

  void _text(Canvas c, String t, Offset center, double size, {bool bold = false, Color color = Colors.black}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas c, Size s) {
    final k = s.width / w;
    Offset p(String id) => Offset(kPos[id]!.dx * k, (h - kPos[id]!.dy) * k);
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFEAF6EC));
    for (final l in kLinks) {
      c.drawLine(p(l[0]), p(l[1]),
          Paint()..color = const Color(0xFFD9DCE3)..strokeWidth = 12 * k..strokeCap = StrokeCap.round);
    }
    for (final l in kLinks) {
      c.drawLine(p(l[0]), p(l[1]), Paint()..color = Colors.white..strokeWidth = 9 * k..strokeCap = StrokeCap.round);
    }
    if (route.length > 1) {
      final path = Path()..moveTo(p(route[0]).dx, p(route[0]).dy);
      for (final id in route.skip(1)) {
        path.lineTo(p(id).dx, p(id).dy);
      }
      c.drawPath(path, Paint()
        ..color = kB
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 * k
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
    }
    for (final sp in kSpots) {
      final o = p(sp.name);
      final isFrom = sp.name == from, isTo = sp.name == to;
      final r = (isFrom || isTo ? 15 : 12) * k;
      c.drawCircle(o, r + 2 * k, Paint()..color = isTo ? kB : (isFrom ? kFound : const Color(0xFFCBD0DB)));
      c.drawCircle(o, r, Paint()..color = Colors.white);
      _text(c, sp.emoji, o, 13 * k);
      _text(c, sp.name, o + Offset(0, r + 8 * k), 8.5 * k, bold: true, color: Colors.black87);
    }
    _text(c, 'N ↑', Offset(s.width - 20 * k, 12 * k), 10 * k, bold: true, color: Colors.black54);
  }

  @override
  bool shouldRepaint(covariant CampusPainter old) => true;
}

class MapScreen extends StatefulWidget {
  final String college;
  final String? dest;
  final int req;
  const MapScreen({super.key, required this.college, this.dest, this.req = 0});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  String? from, to, error;
  List<String> route = [];
  List<RouteStep> steps = [];
  double total = 0;

  @override
  void didUpdateWidget(MapScreen old) {
    super.didUpdateWidget(old);
    if (widget.req != old.req && widget.dest != null) {
      setState(() => to = widget.dest);
      if (from != null) _go();
    }
  }

  void _go() {
    setState(() {
      error = null;
      route = [];
      steps = [];
      if (from == null || to == null) {
        error = 'Choose where you are and where you want to go.'; // error case
        return;
      }
      if (from == to) {
        error = 'You’re already there 🙂'; // error case
        return;
      }
      final r = findRoute(from!, to!);
      if (r == null) {
        error = 'No walking route found between these two places.'; // error case
        return;
      }
      route = r;
      steps = buildSteps(r);
      total = 0;
      for (int i = 0; i < r.length - 1; i++) {
        total += (kPos[r[i]]! - kPos[r[i + 1]]!).distance;
      }
    });
  }

  BoxDecoration get _cardDeco => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22),
      boxShadow: const [BoxShadow(color: Color(0x14783228), blurRadius: 20, offset: Offset(0, 8))]);

  Widget _drop(String label, IconData icon, String? value, void Function(String?) onChanged) =>
      DropdownButtonFormField<String>(
        key: ValueKey('$label$value'),
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label, prefixIcon: Icon(icon, color: kB), filled: true, fillColor: kBg,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
        items: [for (final s in kSpots) DropdownMenuItem(value: s.name, child: Text('${s.emoji}  ${s.name}'))],
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    return ListView(padding: EdgeInsets.zero, children: [
      Container(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 22, 20, 30),
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Campus Map 🗺️', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(widget.college == 'USAR' ? 'Tell us where you are and where you want to go' : widget.college,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: widget.college != 'USAR'
            ? Container(
          width: double.infinity, padding: const EdgeInsets.all(24), decoration: _cardDeco,
          child: Column(children: [
            const Text('🧭', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 8),
            Text('Map for ${widget.college} is coming soon',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 6),
            const Text('USAR is the first campus with walking directions.', textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
          ]),
        )
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(14), decoration: _cardDeco,
            child: Column(children: [
              _drop('I am at', Icons.my_location_rounded, from, (v) {
                from = v;
                if (to != null) _go(); else setState(() {});
              }),
              Row(children: [
                const Expanded(child: Divider()),
                IconButton(
                  icon: const Icon(Icons.swap_vert_rounded, color: kB),
                  onPressed: () {
                    final t = from;
                    from = to;
                    to = t;
                    if (from != null && to != null) _go(); else setState(() {});
                  },
                ),
                const Expanded(child: Divider()),
              ]),
              _drop('I want to go to', Icons.flag_rounded, to, (v) {
                to = v;
                if (from != null) _go(); else setState(() {});
              }),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: kB, padding: const EdgeInsets.all(15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _go,
                  icon: const Icon(Icons.directions_walk_rounded),
                  label: const Text('Show directions', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: AspectRatio(
              aspectRatio: CampusPainter.w / CampusPainter.h,
              child: CustomPaint(painter: CampusPainter(route, from, to)),
            ),
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('🚶 About ${math.max(1, (total / 80).ceil())} min · ${total.round()} m',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 10),
            for (final s in steps)
              Container(
                margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12), decoration: _cardDeco,
                child: Row(children: [
                  CircleAvatar(radius: 18, backgroundColor: kB.withOpacity(.12), child: Icon(s.icon, color: kB, size: 20)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(s.text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.35))),
                  if (s.metres > 0)
                    Text('${s.metres} m', style: const TextStyle(color: Colors.black45, fontWeight: FontWeight.w700, fontSize: 12)),
                ]),
              ),
            const SizedBox(height: 4),
            const Text('Distances are approximate.', style: TextStyle(color: Colors.black38, fontSize: 11)),
          ],
        ]),
      ),
    ]);
  }
}

// ---------- ONE-TIME LOGIN ----------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final name = TextEditingController(), dept = TextEditingController(), contact = TextEditingController();
  bool busy = false;

  InputDecoration _d(String l, IconData i) => InputDecoration(
    labelText: l, prefixIcon: Icon(i), filled: true, fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
  );

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => busy = true);
    String? college;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('p_name', name.text.trim());
      await p.setString('p_dept', dept.text.trim());
      await p.setString('p_contact', contact.text.trim());
      college = p.getString('college');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save your details, continuing anyway')));
      }
    }
    if (!mounted) return;
    final c = college;
    Navigator.pushAndRemoveUntil(
        context, MaterialPageRoute(builder: (_) => c == null ? const CollegeScreen() : Home(college: c)), (r) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Form(
      key: _form,
      child: ListView(padding: EdgeInsets.zero, children: [
        Container(
          padding: EdgeInsets.fromLTRB(22, MediaQuery.of(context).padding.top + 22, 22, 36),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [kA, kB], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(36)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            FindrLogo(size: 54, inverted: true),
            SizedBox(height: 20),
            Text('Welcome to Findr 👋', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            SizedBox(height: 6),
            Text('Tell us about yourself once. We’ll remember it for next time.',
                style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            TextFormField(
              controller: name, textCapitalization: TextCapitalization.words, decoration: _d('Full name', Icons.person_rounded),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: dept, decoration: _d('Department & year (e.g. AI&ML, 2nd year)', Icons.school_rounded),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your department and year' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: contact, decoration: _d('Email or 10-digit phone', Icons.alternate_email_rounded),
              validator: (v) {
                final s = (v ?? '').trim();
                final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s) ||
                    RegExp(r'^\d{10}$').hasMatch(s.replaceAll(RegExp(r'[\s-]'), ''));
                return ok ? null : 'Enter a valid email or phone number';
              },
            ),
            const SizedBox(height: 10),
            const Text('Your contact is only shown on posts you create, so finders and owners can reach you.',
                style: TextStyle(color: Colors.black45, fontSize: 12, height: 1.4)),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kB, padding: const EdgeInsets.all(17),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: busy ? null : _save,
                child: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Text('Continue', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ),
          ]),
        ),
      ]),
    ),
  );
}

// ---------- ERROR SCREEN ----------
class ErrorScreen extends StatelessWidget {
  final String error;
  const ErrorScreen({super.key, required this.error});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('📡', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 12),
          const Text('Can’t connect to Findr', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('Check your internet connection and restart the app.', textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Text(error, maxLines: 4, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black38, fontSize: 11)),
        ]),
      ),
    ),
  );
}