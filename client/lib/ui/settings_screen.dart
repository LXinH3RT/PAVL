/// 设置页。
///
/// 与以前的弹窗相比，这一页要放的东西多了一倍：播放行为、音轨字幕偏好、
/// 本机信息、服务器状态、排查入口。平铺在一列里会滚很久，所以改成
/// 「左侧目录 + 右侧内容」——一次只渲染一类，目录永远在眼前。
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
import '../player/track_prefs.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';
import '../util/build_info.dart';
import '../util/platform_support.dart';

/// 设置页的分类。
///
/// 顺序按「多久动一次」排：播放行为最常调，关于与排查基本只看一眼。
enum SettingsTab {
  playback('播放'),
  tracks('音轨与字幕'),
  local('本机'),
  server('服务器'),
  about('关于与排查');

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

  /// 这台服务器上已记住多少部片。null 表示还在读。
  int? _prefCount;
  bool _prefBusy = false;

  /// 服务端版本。客户端存连接信息时只留了 id 与地址，版本没存，所以开这一
  /// 页时问一次 `/info`。那是免鉴权接口，不必带令牌。
  String? _serverVersion;

  @override
  void initState() {
    super.initState();
    _loadPrefCount();
    _loadServerVersion();
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

  /// 偏好条数要问服务端（安装版）或本地（便携版），只有 [TrackPrefs] 知道
  /// 该问哪边，所以这里必须临时建一个客户端。
  Future<void> _loadPrefCount() async {
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final count = await TrackPrefs(
        client: client,
        store: widget.store,
      ).count();
      if (mounted) setState(() => _prefCount = count);
    } finally {
      client.close();
    }
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

  Future<void> _clearPrefs() async {
    setState(() => _prefBusy = true);
    final client = PavlClient(
      connection: widget.connection,
      deviceId: widget.store.deviceId,
    );
    try {
      final removed = await TrackPrefs(
        client: client,
        store: widget.store,
      ).clear();
      if (!mounted) return;
      setState(() => _prefCount = 0);
      _toast('已清空 $removed 条记录');
    } catch (error) {
      logLine('ui', '清空偏好失败：$error');
      if (mounted) _toast('清空失败：$error');
    } finally {
      client.close();
      if (mounted) setState(() => _prefBusy = false);
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
    // 条数会变：在浏览器里放过片、在别的机器上清空过，都可能让这一格过时。
    // 每次回到这一类就重新问一次，比在 initState 里问一次要准。
    if (tab == SettingsTab.tracks) {
      setState(() => _prefCount = null);
      _loadPrefCount();
    }
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
            title: const Text('记住每部片的音轨与字幕'),
            subtitle: const Text(
              '关掉后不再记录选择，也不会自动切换。已经记下的内容仍保留，'
              '重新打开开关就恢复生效。',
            ),
            onChanged: (value) => _persist(
              () => widget.store.rememberTracks = value,
            ),
          ),
          ListTile(
            title: const Text('播放设置存在哪'),
            subtitle: Text(_storageHint),
            trailing: Text(
              _storageLabel,
              style: const TextStyle(fontSize: 13, color: PavlColors.textDim),
            ),
          ),
        ];

      case SettingsTab.tracks:
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              '打开一部片时，会先按 id 找回上次选的那条轨。找不到（换集、转封装、'
              '重新压制都可能改 id）就退到同语言、同标题的轨；用户上次选了国语，'
              '这一集多半还想听国语。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.6,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              '外挂字幕优先于内嵌轨：手动挑过的字幕更贴近意图。同一目录下的 '
              'srt/ass 会在打开时按文件名自动匹配。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.6,
              ),
            ),
          ),
          const Divider(height: 24),
          ListTile(
            title: const Text('已记住的影片'),
            subtitle: Text(
              _prefCount == null ? '读取中…' : '$_prefCount 部',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: (_prefBusy || (_prefCount ?? 0) == 0)
                    ? null
                    : _clearPrefs,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清空全部记录'),
              ),
            ),
          ),
        ];

      case SettingsTab.local:
        return [
          _KvTile(label: '设备名', value: widget.store.deviceName),
          _KvTile(label: '设备 ID', value: widget.store.deviceId),
          _KvTile(label: '数据目录', value: appDataDir().path),
          _KvTile(label: '平台', value: platformLabel),
        ];

      case SettingsTab.server:
        return [
          _KvTile(label: '名称', value: widget.connection.name),
          _KvTile(
            label: '地址',
            value: '${widget.connection.host}:${widget.connection.port}',
          ),
          _KvTile(label: '状态', value: widget.connection.paired ? '已配对' : '未配对'),
          _KvTile(label: '存储形态', value: _storageLabel),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _storageLabel == '安装版'
                  ? '安装版服务端可能给多台机器用，所以每台机器的音轨字幕选择'
                      '存在服务端，并按设备区分。换一台设备看同一部片，各记各的。'
                  : '便携版服务端的程序文件夹可能被整个拷给别人，把选择存在那边'
                      '等于把自己的偏好带给别人，所以存在本机。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.6,
              ),
            ),
          ),
        ];

      case SettingsTab.about:
        return [
          _KvTile(label: '客户端版本', value: appVersion),
          _KvTile(label: '服务端版本', value: _serverVersionText),
          const Divider(height: 24),
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

  String get _storageLabel =>
      widget.connection.serverStoresPrefs ? '安装版' : '便携版';

  String get _storageHint => widget.connection.serverStoresPrefs
      ? '这台服务器是安装版，音轨字幕选择存在服务端，按设备区分，不跨设备同步。'
      : '这台服务器是便携版，音轨字幕选择存在本机，跟着客户端文件夹走。';

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
