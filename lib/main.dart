import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'dart:async';

import 'pages/home_page.dart';
import 'pages/audio_page.dart';
import 'pages/library_page.dart';
import 'pages/mine_page.dart';
import 'pages/notes_page.dart';
import 'services/app_log.dart';
import 'services/app_theme.dart';
import 'services/audio_preferences.dart';
import 'services/backend_service.dart';
import 'services/detail_snapshot_cache.dart';
import 'services/library_store.dart';
import 'services/reading_stats_store.dart';
import 'services/share_service.dart';
import 'services/poster_cache.dart';
import 'services/shelf_store.dart';
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/home/home_design.dart';

void main() {
  // 【青茄重构·修复】绑定初始化与 runApp 必须落在**同一个 zone**：
  // 原先 ensureInitialized() 在根 zone、runApp 在 runZonedGuarded 的子 zone，
  // debug 模式启动即抛 "Zone mismatch"（BindingBase.debugCheckZone），
  // 且子 zone 的未捕获异常处理对绑定回调不生效。
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // 【青茄·竖屏】全应用只接受竖屏：手机横过来时界面保持竖向，不再整体
    // 转成横向排版（阅读、听书、笔记都在竖屏完成）。清单里的
    // android:screenOrientation="portrait" 在系统层兜同一件事，避免
    // 启动瞬间先转一次再被 Flutter 拉回来。
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    // 应用内日志：接管 debugPrint 与 FlutterError.onError，未处理异步异常由
    // runZonedGuarded 捕获；文件持久化异步开启，失败只退回内存模式。
    AppLog.instance.install();
    unawaited(AppLog.instance.startPersistence());
    // 通用系统分享走 Android 的 Intent.ACTION_SEND
    //（官方同一条路径）。桥不可用时 PlayletShare 自动降级为复制链接，
    // 不会把失败说成成功。
    // 插件回 false 表示没能调起选择器（没有可分享的应用），必须原样返回：
    // 「调不起来」与「已分享」是两件事。
    SharePlusLite.handler = ({required title, required text}) async {
      final launched = await const MethodChannel(
        'fqapp/share',
      ).invokeMethod<bool>('shareText', {'title': title, 'text': text});
      return launched ?? false;
    };
    // Rust 核心日志的读取入口：日志页「Rust」视图读 runtime_dir/rust.log。
    // 核心只在 Android 落盘（桌面/测试构建不装 logger），读不到时页面给空态。
    RustLogSource.reader = BackendService.instance.readRustLog;
    runApp(const ProviderScope(child: FqApp()));
    // 【青茄修复·启动提速】Rust 后端进程的拉起（解压/端口/握手）是
    // 启动最耗时的一步，与本地数据初始化完全独立。这里就并发开跑，
    // RootShell 等待的是同一个 Future（start() 可重入），总耗时从
    // 「本地 + 后端 相加」变成「两者取最大」。失败由 RootShell 的
    // 错误态统一展示，这里吞掉即可。
    unawaited(
      BackendService.instance.start().then((_) {}, onError: (Object _) {}),
    );
  }, (error, stack) => AppLog.e('zone', '未捕获异步异常', error: error, stack: stack));
}

Future<void> _initializeLocalData() async {
  await Hive.initFlutter();
  // 【青茄修复·启动提速】AppBootstrap 会等本方法返回才放出首页。
  // 首页真正依赖的只有三个：书架历史、书架收藏、偏好（含主题），
  // 三者互相独立，并行打开；其余可选数据挪到 [_initializeOptionalData]，
  // 在首帧之后继续，不再串行拖住进入首页。
  final spFuture = _loadPreferencesSafely();
  await Future.wait([LibraryStore.instance.init(), ShelfStore.instance.init()]);
  final sp = await spFuture;
  // The 加入书架 collection is optional data: a failure here must not block
  // startup, which is why it shares the retryable bootstrap with the history.
  await ShelfStore.instance.init();
  _initializeOptionalData();
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  if (sp != null) {
    final savedTheme = sp.get(themeModeKey);
    themeModeNotifier.value = themeModeFromName(
      savedTheme is String ? savedTheme : null,
    );
    // 墨水屏模式与深色模式同为可选偏好：读不到退化为关闭，不拖住启动。
    einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
  }
}

/// Preferences are useful, but a platform-plugin failure must not make the
/// whole local library unreadable. The Hive-backed bookshelf and history can
/// still open, so startup falls back to product defaults and records the real
/// error for the in-app log page.
Future<SharedPreferences?> _loadPreferencesSafely() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (error, stack) {
    AppLog.w('bootstrap', '偏好读取失败，继续使用默认偏好', error: error, stack: stack);
    return null;
  }
}

/// Local work that can finish after the first frame without blocking startup.
Future<void> _initializeOptionalData() async {
  unawaited(AudioPreferences.instance.load());
  unawaited(PosterCache.instance.enforceBudget());
  // 详情页快照盒：首帧之后再打开，之后每次进详情都是同步命中。
  unawaited(DetailSnapshotCache.instance.load());
  // 字数口径 v2：把旧的「打开整章即整章计数」重算成「时长 × 阅读速度」。
  // 只跑一次（store 内部用 schema 版本位兜底），失败就沿用旧数据。
  unawaited(
    ReadingStatsStore.instance
        .migrateToTimeEstimate(LibraryStore.instance.readTimeSnapshot())
        .catchError((_) {}),
  );
}

class FqApp extends StatefulWidget {
  const FqApp({super.key});

  @override
  State<FqApp> createState() => _FqAppState();
}

class _FqAppState extends State<FqApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, eink, _) {
            // 墨水屏强制浅色纯黑白：深色反白在墨水屏上残影最重。
            final effectiveMode = eink ? ThemeMode.light : mode;
            return MaterialApp(
              navigatorKey: _navigatorKey,
              navigatorObservers: [AudioRouteWatcher.instance],
              builder: (context, child) => AudioPlaybackScope(
                navigatorKey: _navigatorKey,
                child: child ?? const SizedBox.shrink(),
              ),
              title: '青茄阅读',
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light, eink: eink),
              darkTheme: _theme(Brightness.dark, eink: eink),
              themeMode: effectiveMode,
              // 日间/夜间/跟随系统切换时整棵树的 ColorScheme 做 220ms 插值，
              // 背景、文字、图标一起渐变，而不是一帧闪白/闪黑。
              // 墨水屏下保持瞬时切换（插值会留残影）。
              themeAnimationDuration: eink
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              themeAnimationCurve: Curves.easeOutCubic,
              home: const AppBootstrap(child: RootShell()),
            );
          },
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness, {bool eink = false}) =>
      AppTheme.createTheme(brightness, einkMode: eink);
}

/// Opens local data before any page can access LibraryStore's boxes. Failed
/// initialization is retryable without clearing or replacing the user's data.
/// See .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
class AppBootstrap extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initializer;

  const AppBootstrap({super.key, required this.child, this.initializer});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _initializing = false;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    setState(() {
      _initializing = true;
      _failed = false;
    });
    try {
      await (widget.initializer ?? _initializeLocalData)();
      if (mounted) setState(() => _ready = true);
    } catch (error, stack) {
      AppLog.e('bootstrap', '本地数据初始化失败', error: error, stack: stack);
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_failed)
                  Icon(
                    LucideIcons.triangle_alert,
                    color: Theme.of(context).colorScheme.error,
                  )
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_failed ? '无法读取本地数据' : '正在读取本地数据…'),
                if (_failed) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '本地数据未被清除，请重试；若仍失败，请反馈应用日志。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _initialize,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  final Future<void> Function()? backendStarter;

  const RootShell({super.key, this.backendStarter});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _startBackend();
  }

  Future<void> _startBackend() async {
    try {
      await (widget.backendStarter ?? BackendService.instance.start)();
    } catch (e) {
      // 【青茄修复·启动提速】后端失败不再扣住整页：弹一条可重试的提示，
      // 页面照常显示（本地功能全可用；在线功能由请求侧等待/重试）。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('本地服务启动失败：$e'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: '重试', onPressed: _startBackend),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 【青茄重构·删除】短剧 tab（原 index 1）已移除，剩余三页均为浅色内容页，
    // 状态栏与玻璃拟态配色只跟随系统明暗，不再需要 isDramaTab 特判。
    final glassDark = isDark;
    // 墨水屏模式：本 build 由 Theme 变化触发重建（上面读了 Theme.of），
    // 这里直接读 notifier 当前值即可拿到最新开关，不另加监听。
    final eink = einkModeNotifier.value;
    final navBar = NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: eink
            ? Colors.black
            : HomePalette.accent.withValues(alpha: glassDark ? 0.20 : 0.12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? (eink ? Colors.white : HomePalette.accent)
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (eink
                      ? Colors.black
                      : (glassDark ? HomePalette.accent : palette.accentText))
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
      ),
      child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i != _index) setState(() => _index = i);
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        destinations: const [
          NavigationDestination(
            icon: Icon(LucideIcons.house),
            selectedIcon: Icon(LucideIcons.house),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.library_big),
            selectedIcon: Icon(LucideIcons.library_big),
            label: '书架',
          ),
          // 【青茄重构·新增】笔记升为主导航：批注/书摘是核心能力，
          // 要能从任意位置一步到达（点条目回原文）。
          NavigationDestination(
            icon: Icon(LucideIcons.pen_line),
            selectedIcon: Icon(LucideIcons.pen_line),
            label: '笔记',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.circle_user_round),
            selectedIcon: Icon(LucideIcons.circle_user_round),
            label: '我的',
          ),
        ],
      ),
    );

    // 【青茄修复·启动提速】不再用「正在启动本地服务」的整页加载门挡住
    // 首页：首页内容是本地的（书单/缓存封面），后端只服务搜索与在线阅读。
    // 后台把服务拉起来；某次启动失败时用 SnackBar 提示 + 可重试，不再
    // 把所有页面一起扣住 2~3 秒。
    // 【青茄修复·底栏固定】extendBody 关闭：底栏是实心固定条（对齐番茄
    // 正式版的处理），正文不再垫到底栏后面。之前悬浮玻璃条 + extendBody
    // 会让每个列表的底部内容被底栏遮住一截，页内只好各自垫大 padding。
    return Scaffold(
      extendBody: false,
      // 状态栏图标亮度挂在壳层、按主题明暗切换。样式放壳层而不是各页内部，
      // 是因为 IndexedStack 里未选中的页不参与绘制，页内 AnnotatedRegion
      // 切走后会残留上一个页的样式。
      // 【青茄重构】删除短剧 tab 后不再有黑底视频流页面，无需按 tab 特判。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: LazyIndexedStack(
          index: _index,
          children: [
            const HomePage(),
            // 【青茄重构·删除】原第二个页面为 DramaPage（短剧 feed），
            // 主导航为 首页/书架/笔记/我的 四 tab。
            // 空书架上的「去书城找书」切回首页 tab。
            LibraryPage(onBrowse: () => setState(() => _index = 0)),
            const NotesPage(),
            const MinePage(),
          ],
        ),
      ),
      // 【青茄修复·底栏固定】整宽实色固定条（学习番茄正式版的处理方式，
      // 样式保持青茄配色）：不悬浮、不圆角、不毛玻璃；顶部一条细分隔线
      // 与正文区分，SafeArea 只保手势区高度。
      bottomNavigationBar: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            color: eink
                ? Colors.white
                : (glassDark ? const Color(0xFF161619) : Colors.white),
            border: Border(
              top: BorderSide(
                color: eink
                    ? Colors.black
                    : (glassDark
                          ? Colors.white.withValues(alpha: 0.10)
                          : palette.line),
                width: eink ? 0.8 : 0.6,
              ),
            ),
          ),
          child: SafeArea(top: false, left: false, right: false, child: navBar),
        ),
      ),
    );
  }
}
