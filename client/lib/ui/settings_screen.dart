/// 设置页。
///
/// 只留两类：播放行为与关于。音轨字幕的记忆开关在「播放」里，设备信息、
/// 服务器信息、许可与排查入口都在「关于」里，一屏能看到底。以前拆成五类，
/// 每类只有两三行，翻页的成本比找东西的成本还高。
///
/// 窗口窄到放不下侧栏时目录改到顶部横排，条目一个不少。桌面端现在的分辨率
/// 基本都用不到窄屏，但布局按宽度判断而不是按平台判断，将来上移动端时不用
/// 重写这一页。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';
import '../util/build_info.dart';
import '../util/platform_support.dart';

/// 随包分发的许可证文件。
///
/// 与仓库根的 `LICENSE` 必须逐字一致，`scripts/package.py` 打包前会比一遍，
/// 不一致就中止。客户端内嵌一份是为了让「关于 → 许可」不依赖安装目录里的
/// LICENSE.txt 还在不在：macOS 的许可放在 .app 外面，Windows 上也可能被单独删掉。
const String licenseAssetPath = 'assets/LICENSE.txt';

/// 设置页的分类。
///
/// 顺序按「多久动一次」排：播放行为最常调，关于基本只看一眼。
enum SettingsTab {
  playback('播放'),
  about('关于');

  const SettingsTab(this.label);

  final String label;

  /// 目录项自己的定位键。
  ///
  /// 按 key 找而不是按文案找：文案以后可能改，「播放」这种词在多处出现，
  /// 靠文字定位说不清点到的是哪一个。
  Key get tabKey => ValueKey('settings-tab-$name');

  /// 目录项与正文标题共用的字号来源。
  TextStyle? textStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.connection,
    this.initialTab,
  });

  final AppStore store;
  final ServerConnection connection;

  /// 打开时落在哪一格，默认「播放」。
  final SettingsTab? initialTab;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ScrollController _scroll = ScrollController();

  late SettingsTab _tab = widget.initialTab ?? SettingsTab.playback;

  /// 服务端版本。客户端存连接信息时只留了 id 与地址，版本没存，所以开这一
  /// 页时问一次 `/info`。那是免鉴权接口，不必带令牌。
  String? _serverVersion;

  /// 服务端的刮削配置。拿不到就保持 null，界面上只留客户端的显示开关。
  ScrapeConfig? _scrape;

  /// 是否正在把刮削配置写回服务端。改来源要串行发请求，避免几个开关同时改
  /// 时后发的把先发的覆盖掉。
  bool _scrapeBusy = false;

  @override
  void initState() {
    super.initState();
    _loadServerVersion();
    _loadScrapeConfig();
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialTab != null && widget.initialTab != old.initialTab) {
      _tab = widget.initialTab!;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 问一次服务端版本。失败不提示，这一格显示「未知」就够了。
  Future<void> _loadServerVersion() async {
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final info = await client.info();
      final version = info['version'];
      if (mounted && version is String) {
        setState(() => _serverVersion = version);
      }
    } catch (error) {
      logLine('ui', '读取服务端版本失败：$error');
    } finally {
      client.close();
    }
  }

  /// 设置项的改动统一走这里：先改内存再存盘，存盘失败要告诉用户。
  ///
  /// 不 await 存盘就关页面的情况是真实存在的（用户拨完开关立刻按返回），
  /// 所以存盘交给 zone 自己跑完，界面不等它。
  void _persist(void Function() change) {
    setState(change);
    _save();
  }

  /// 问一次服务端的刮削配置。
  ///
  /// 失败只记日志：老服务端没有这几个接口，设置页不该因此报错，客户端的显示
  /// 开关照样能用。
  Future<void> _loadScrapeConfig() async {
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final config = await client.scrapeConfig();
      if (mounted) setState(() => _scrape = config);
    } catch (error) {
      logLine('ui', '读取刮削配置失败：$error');
    } finally {
      client.close();
    }
  }

  /// 把刮削配置写回服务端。
  ///
  /// 只在用户动服务端那几项时调用；客户端自己的显示开关走 [_persist]，不必
  /// 联网。
  Future<void> _saveScrapeConfig({
    bool? enabled,
    bool? autoMatch,
    List<String>? sources,
  }) async {
    if (_scrapeBusy) return;
    setState(() => _scrapeBusy = true);
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final config = await client.updateScrapeConfig(
        enabled: enabled,
        autoMatch: autoMatch,
        sources: sources,
      );
      if (mounted) setState(() => _scrape = config);
    } catch (error) {
      logLine('ui', '保存刮削配置失败：$error');
      if (mounted) {
        _toast('服务端没有接受这项改动：$error');
        // 失败时把界面拉回服务端的真实状态，别让开关停在没生效的位置。
        await _loadScrapeConfig();
      }
    } finally {
      client.close();
      if (mounted) setState(() => _scrapeBusy = false);
    }
  }

  Future<void> _save() async {
    try {
      await widget.store.save();
    } catch (error) {
      logLine('ui', '保存设置失败：$error');
      if (mounted) _toast('设置没能保存到磁盘：$error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _select(SettingsTab tab) {
    setState(() => _tab = tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: PavlColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final body = _pane(context);
          // 侧栏要 220，正文至少留 500 才不至于每行折三行。
          if (box.maxWidth < 720) {
            return Column(
              children: [
                _TabStrip(current: _tab, onSelect: _select),
                const Divider(height: 1),
                Expanded(child: body),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 220,
                child: _TabRail(current: _tab, onSelect: _select),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  /// 右侧内容区，只构建当前这一类的行。
  Widget _pane(BuildContext context) {
    return ListView(
      // 换分类等于换一页，滚动位置跟着归零。
      key: ValueKey('settings-pane-${_tab.name}'),
      controller: _scroll,
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: _rowsFor(_tab),
    );
  }

  List<Widget> _rowsFor(SettingsTab tab) {
    switch (tab) {
      case SettingsTab.playback:
        return [
          SwitchListTile(
            value: widget.store.crossDeviceProgress,
            title: const Text('跨设备同步进度'),
            subtitle: const Text(
              '关闭时只看本机自己的记录；打开后使用服务端保存的最近一次位置，'
              '任何设备播过都会在这里继续。',
            ),
            onChanged: (value) => _persist(
              () => widget.store.crossDeviceProgress = value,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              widget.store.crossDeviceProgress
                  ? '当前：打开视频时提示最近一次播放位置（可能来自别的设备）。'
                  : '当前：打开视频时只提示这台设备自己的上次位置。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.5,
              ),
            ),
          ),
          SwitchListTile(
            value: widget.store.rememberTracks,
            title: const Text('音轨与字幕记忆'),
            subtitle: const Text(
              '关掉后不再记录选择，也不会自动切换。已经记下的内容仍保留，'
              '重新打开开关就恢复生效。',
            ),
            onChanged: (value) => _persist(
              () => widget.store.rememberTracks = value,
            ),
          ),
          // 存储位置只做告知，不提供切换：跟着哪一边由服务端形态决定。
          ListTile(
            title: const Text('配置存储位置'),
            subtitle: Text(_storageHint),
          ),
          const Divider(height: 24),
          const _SectionTitle('片库'),
          SwitchListTile(
            value: widget.store.useScrape,
            title: const Text('显示刮削信息'),
            subtitle: const Text(
              '打开后片库里的文件夹行会显示海报、年份、评分与类型。'
              '刮削本身在服务端做，关掉只是这台设备不再显示。',
            ),
            onChanged: (value) => _persist(
              () => widget.store.useScrape = value,
            ),
          ),
          ..._scrapeRows(),
        ];

      case SettingsTab.about:
        return [
          const _SectionTitle('应用'),
          _KvTile(label: '客户端版本', value: appVersion),
          _KvTile(label: '服务端版本', value: _serverVersionText),
          ListTile(
            title: const Text('许可'),
            subtitle: const Text('PAVL 与第三方组件的许可条款'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: _showLicense,
          ),
          const Divider(height: 24),
          const _SectionTitle('本机'),
          _KvTile(label: '设备名', value: widget.store.deviceName),
          _KvTile(label: '设备 ID', value: widget.store.deviceId),
          _KvTile(label: '数据目录', value: appDataDir().path),
          _KvTile(label: '平台', value: platformLabel),
          const Divider(height: 24),
          const _SectionTitle('服务器'),
          _KvTile(label: '名称', value: widget.connection.name),
          _KvTile(
            label: '地址',
            value: '${widget.connection.host}:${widget.connection.port}',
          ),
          _KvTile(label: '状态', value: widget.connection.paired ? '已配对' : '未配对'),
          _KvTile(label: '存储形态', value: _storageLabel),
          const Divider(height: 24),
          const _SectionTitle('排查'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: const Text(
              '播放出问题时，日志里会记下失败原因。点下面的按钮复制路径，'
              '把 client.log 发过来即可定位。',
              style: TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.6,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: _copyLogPath,
                  child: const Text('复制日志路径'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _openLogFolder,
                  child: const Text('打开日志目录'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '${logFile().path}'
              '${File(logFile().path).existsSync() ? '' : '（还没有生成，播一次就会出现）'}',
              style: const TextStyle(fontSize: 11, color: PavlColors.textDim),
            ),
          ),
        ];
    }
  }

  /// 服务端版本。
  String get _serverVersionText {
    final version = _serverVersion;
    if (version == null || version.isEmpty) return '未知';
    return version;
  }

  /// 服务端刮削那几行。
  ///
  /// 老版本服务端没有 `/scrape/settings`，`_scrape` 会一直是 null —— 这时候
  /// 干脆不画这一段，而不是画一堆点不动的开关。
  List<Widget> _scrapeRows() {
    final scrape = _scrape;
    if (scrape == null) return const [];
    return [
      SwitchListTile(
        value: scrape.enabled,
        title: const Text('服务端刮削'),
        subtitle: const Text(
          '开启后服务端会按片名去豆瓣、IMDb、B站找海报与简介。'
          '关掉后不再联网，已经抓到的记录仍保留在服务端。',
        ),
        onChanged: _scrapeBusy
            ? null
            : (value) => _saveScrapeConfig(enabled: value),
      ),
      if (scrape.enabled) ...[
        SwitchListTile(
          value: scrape.autoMatch,
          title: const Text('自动匹配'),
          subtitle: const Text(
            '片库里出现新片时，只有片名高度吻合才自动采纳，'
            '拿不准的留给手动选择。',
          ),
          onChanged: _scrapeBusy
              ? null
              : (value) => _saveScrapeConfig(autoMatch: value),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
            '信息来源',
            style: const TextStyle(
              fontSize: 12.5,
              color: PavlColors.textDim,
            ),
          ),
        ),
        for (final option in scrape.availableSources)
          CheckboxListTile(
            value: scrape.sources.contains(option.id),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(option.label),
            // 关掉最后一个源就没得刮了，禁掉这一格而不是让用户点了没反应。
            onChanged: _scrapeBusy ||
                    (scrape.sources.length == 1 &&
                        scrape.sources.contains(option.id))
                ? null
                : (checked) => _toggleSource(option.id, checked ?? false),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            _scrapeStatusText(scrape),
            style: const TextStyle(
              fontSize: 12.5,
              color: PavlColors.textDim,
              height: 1.5,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _scrapeBusy || scrape.running
                    ? null
                    : _runAutoScrape,
                child: Text(scrape.running ? '正在刮削' : '刮削整个片库'),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _scrapeBusy ? null : _clearScrape,
                child: const Text('清除刮削记录'),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  String _scrapeStatusText(ScrapeConfig scrape) {
    final count = scrape.recordCount;
    if (scrape.running) {
      return '正在后台刮削，可以继续浏览，完成后回到这里看结果。';
    }
    if (count <= 0) {
      return '还没有刮到任何影片。点「刮削整个片库」开始，'
          '片名与文件名差别较大时可能找不到，可以再手动挑。';
    }
    return '已经刮到 $count 部影片。';
  }

  /// 勾选或取消一个来源。
  ///
  /// 服务端要求至少留一个源，所以最后一个是禁用的；这里再兜一层，避免并发
  /// 点击把列表清空。
  void _toggleSource(String id, bool checked) {
    final scrape = _scrape;
    if (scrape == null) return;
    final next = [...scrape.sources];
    if (checked) {
      if (!next.contains(id)) next.add(id);
    } else {
      next.remove(id);
      if (next.isEmpty) return;
    }
    // 保持「豆瓣、IMDb、B站」的固定顺序，界面上勾选顺序不会来回跳。
    next.sort((a, b) => scrape.availableSources
        .indexWhere((e) => e.id == a)
        .compareTo(scrape.availableSources.indexWhere((e) => e.id == b)));
    _saveScrapeConfig(sources: next);
  }

  /// 让服务端在后台把整个片库扫一遍。
  Future<void> _runAutoScrape() async {
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final folders = await client.scrapeAuto();
      if (mounted) {
        _toast(folders > 0
            ? '已交给服务端处理 $folders 个文件夹，稍后回来看结果'
            : '片库里没有需要刮削的条目');
      }
    } catch (error) {
      logLine('ui', '启动刮削失败：$error');
      if (mounted) _toast('没能启动刮削：$error');
    } finally {
      client.close();
    }
  }

  /// 清空服务端保存的刮削记录。
  ///
  /// 二次确认：这会连海报一起删掉，重新刮要花不少时间。
  Future<void> _clearScrape() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除刮削记录'),
        content: const Text('会删掉服务端保存的全部刮削信息与海报，下次要重新刮。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      await client.scrapeClear();
      if (!mounted) return;
      _toast('已清除');
      await _loadScrapeConfig();
    } catch (error) {
      logLine('ui', '清除刮削记录失败：$error');
      if (mounted) _toast('没能清除：$error');
    } finally {
      client.close();
    }
  }

  String get _storageLabel =>
      widget.connection.serverStoresPrefs ? '安装版' : '便携版';

  /// 「配置存储位置」那一行的说明：只回答「跟着谁走」。
  ///
  /// 形态怎么判定、为什么这么分属于实现细节，写在 README 里，不占设置页。
  String get _storageHint {
    if (!widget.connection.serverStoresPrefs) return '跟随本机客户端目录';
    final name = widget.connection.name.trim();
    return name.isEmpty ? '跟随服务端目录' : '跟随“$name”目录';
  }

  /// 打开许可全文。
  ///
  /// 读的是随包分发的 asset，而不是安装目录里的 LICENSE.txt：那份文件在
  /// macOS 上位于 .app 之外，Windows 上也可能被单独删掉。
  Future<void> _showLicense() async {
    final String text;
    try {
      text = await rootBundle.loadString(licenseAssetPath);
    } catch (error) {
      logLine('ui', '读取许可证失败：$error');
      if (mounted) _toast('许可没能打开：$error');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _LicenseDialog(text: text),
    );
  }

  Future<void> _copyLogPath() async {
    await Clipboard.setData(ClipboardData(text: logFile().path));
    if (mounted) _toast('日志路径已复制');
  }

  /// 在系统文件管理器里打开日志文件所在的目录。
  ///
  /// 目录可能还不存在（从没播放过），先建出来。打不开时退回「把路径复制到
  /// 剪贴板」，而不是弹一个用户看不懂的系统错误框。
  Future<void> _openLogFolder() async {
    final dir = logFile().parent;
    try {
      await dir.create(recursive: true);
    } catch (_) {
      // 建不出来时仍然试一下打开，由打开命令自己报错。
    }

    final opened = await openDirectoryInFileManager(dir.path);
    if (!opened) logLine('ui', '打开日志目录失败：${dir.path}');

    if (opened || !mounted) return;
    await Clipboard.setData(ClipboardData(text: dir.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('系统打不开文件管理器，路径已复制：${dir.path}'),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

/// 小节标题：「应用」「本机」「服务器」「排查」。
///
/// 与连接页的同类标题保持一套字号与字重，设置页里不另起一种。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 20, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: PavlColors.textDim,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

/// 许可全文弹窗。
///
/// 条款是纯文本，内容比屏幕长，所以整块可滚动，并且允许选中复制——把某段
/// 条款贴到别处是常见需求。
class _LicenseDialog extends StatelessWidget {
  const _LicenseDialog({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: PavlColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: media.height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '许可',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontSize: 12.5, height: 1.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 宽屏的左侧目录栏。
class _TabRail extends StatelessWidget {
  const _TabRail({required this.current, required this.onSelect});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final tab in SettingsTab.values)
          _TabTile(
            tab: tab,
            selected: tab == current,
            onTap: () => onSelect(tab),
          ),
      ],
    );
  }
}

/// 窄屏的顶部目录条：同一张表，横排。
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.current, required this.onSelect});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final tab in SettingsTab.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _TabTile(
                tab: tab,
                selected: tab == current,
                onTap: () => onSelect(tab),
                compact: true,
              ),
            ),
        ],
      ),
    );
  }
}

class _TabTile extends StatelessWidget {
  const _TabTile({
    required this.tab,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final SettingsTab tab;
  final bool selected;
  final VoidCallback onTap;

  /// 横排时按内容撑开，不占整行。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 选中与否只靠颜色和底色区分，不改字号：大小一变，扫视时会觉得目录
    // 与正文是两个层级的东西。
    final style = tab.textStyle(context)?.copyWith(
          color: selected ? PavlColors.accent : PavlColors.text,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );
    if (compact) {
      return InkWell(
        key: tab.tabKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? PavlColors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(tab.label, style: style),
        ),
      );
    }
    return InkWell(
      key: tab.tabKey,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? PavlColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              width: 3,
              color: selected ? PavlColors.accent : Colors.transparent,
            ),
          ),
        ),
        child: Text(tab.label, style: style),
      ),
    );
  }
}

/// 「键：值」一行，值可以选中复制。
///
/// 设备 ID、数据目录这类东西是给排查用的，用户要能把它们贴到聊天窗口里，
/// 所以用 [SelectableText] 而不是普通 [Text]。
class _KvTile extends StatelessWidget {
  const _KvTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标签按内容取宽，不写死像素：系统文字放大后固定宽度会把
          // 「客户端版本」折成两行。上限防止某个超长标签把值挤没。
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: PavlColors.textDim),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
