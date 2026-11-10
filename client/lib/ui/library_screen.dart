/// 片库页：把整个共享目录里的视频按文件夹收拢后列出来，配搜索与分页。
///
/// 与浏览页的区别是「不关心文件放在哪一层」：浏览页按目录一层层进，片库直接
/// 把同一文件夹里的多个视频收成一行，行上写集数，点开才展开各集。这样一部
/// 几十集的剧只占一行，找片不必一路往下滚。文件名仍然是完整的——展开后看到
/// 的还是原始文件名，只是不再挤满屏。两页都保留：按目录找是已知路径时的快
/// 路，片库是「记不住放哪儿」时的兜底。
///
/// 收拢、排序与分页都由服务端完成：客户端只发页码和关键词。这样做是因为分页
/// 是把全库切片后发过来的，客户端若只对当前页重排，跨页顺序会乱；文件夹也只
/// 能在服务端整份索引上切分，客户端拿到的若已经是页码切过的碎片，同一个文件夹
/// 就会被切到两页里去。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';
import 'player_screen.dart';
import 'widgets/library_tile.dart';

/// 每页条数。取值考虑两点：足够填满一屏（避免首屏就要翻页），又不能让
/// 单个响应太大——片库条目带标题解析结果，一条约 300 字节。
const int libraryPageSize = 100;

/// 片库页。
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.store,
    required this.client,
  });

  final AppStore store;
  final PavlClient client;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  LibraryPage _page = LibraryPage.empty;
  final List<LibraryGroup> _items = [];

  /// 已经展开的文件夹（键是 `LibraryGroup.path`）。
  ///
  /// 展开状态只活在页面里：离开片库再回来时还是收拢的。记住它反而会让人困惑
  /// ——过几天再看，列表里一半是收拢一半是摊开的，比全收拢更乱。
  final Set<String> _expanded = {};

  int _pageNo = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _keyword = '';

  /// 最近播放，显示在顶部。为空就不占位置。
  List<RecentEntry> _recent = const [];

  /// 请求序号。搜索框里连着敲字会发出多个请求，只认最后一个的结果。
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 提前两屏开始加载，滚到底时通常已经备好了，不会白等。
    if (position.pixels + position.viewportDimension * 2 >=
        position.maxScrollExtent) {
      unawaited(_loadMore());
    }
  }

  /// 从头拉第一页，同时刷新最近播放。
  Future<void> _reload() async {
    final token = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.client.library(
        page: 1,
        pageSize: libraryPageSize,
        query: _keyword,
      );
      final recent = await widget.client.recent(limit: 8);
      if (!mounted || token != _requestId) return;
      setState(() {
        _page = page;
        _pageNo = 1;
        _items
          ..clear()
          ..addAll(page.items);
        // 换了关键词就是另一批结果，旧的行早已不在，展开记录留着只会越攒越多。
        _expanded.clear();
        _recent = recent;
        _loading = false;
      });
      logLine('library',
          '片库第 1 页 ${page.items.length} 项，共 ${page.total} 项 / ${page.videoTotal} 部视频');
    } on PavlApiError catch (error) {
      if (!mounted || token != _requestId) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on PavlNetworkError catch (error) {
      if (!mounted || token != _requestId) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  /// 追加下一页。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_page.hasMore) return;
    final token = _requestId;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.library(
        page: _pageNo + 1,
        pageSize: libraryPageSize,
        query: _keyword,
      );
      // 加载途中用户改了搜索词，这一页已经不属于当前结果集，直接丢掉。
      if (!mounted || token != _requestId) return;
      setState(() {
        _page = page;
        _pageNo = page.page;
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || token != _requestId) return;
      setState(() => _loadingMore = false);
      logLine('library', '加载下一页失败：$error');
    }
  }

  void _onSearchChanged(String value) {
    final next = value.trim();
    if (next == _keyword) return;
    _keyword = next;
    unawaited(_reload());
  }

  Future<void> _open(MediaEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          store: widget.store,
          client: widget.client,
          path: entry.path,
          fallbackTitle: entry.displayTitle,
        ),
      ),
    );
    // 回来时进度可能变了，最近播放要跟着更新。
    if (mounted) unawaited(_reload());
  }

  Future<void> _openRecent(RecentEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          store: widget.store,
          client: widget.client,
          path: entry.path,
          fallbackTitle: entry.displayName,
        ),
      ),
    );
    if (mounted) unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.video_library_outlined,
                size: 18, color: PavlColors.textDim),
            SizedBox(width: 8),
            Text('片库', style: TextStyle(fontSize: 16)),
          ],
        ),
        backgroundColor: PavlColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _searchBar(),
        ),
      ),
      body: _body(),
    );
  }

  Widget _searchBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      alignment: Alignment.centerLeft,
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: '按标题或路径搜索',
          hintStyle: const TextStyle(fontSize: 13, color: PavlColors.textDim),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 32),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '清除',
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                ),
          filled: true,
          fillColor: PavlColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: PavlColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: PavlColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: PavlColors.accent),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: PavlColors.textDim),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: PavlColors.textDim)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _keyword.isEmpty ? '片库里还没有视频' : '没有匹配「$_keyword」的视频',
          style: const TextStyle(color: PavlColors.textDim),
        ),
      );
    }

    // 顶部「最近播放」只在没搜索时才显示：搜索时用户要的是搜索结果的完整
    // 列表，混进一批不相关的片子只会干扰。
    final showRecent = _keyword.isEmpty && _recent.isNotEmpty;
    final recentCount = showRecent ? _recent.length : 0;

    // 展开后的各集跟着文件夹行走形。这里先摊平再交给 ListView.builder，是为了
    // 让懒加载按「屏幕上的行」算——展开一个 200 集的文件夹时，只有滚到眼前的
    // 那几集会被构建。
    final rows = <_VisibleRow>[];
    for (final group in _items) {
      rows.add(_VisibleRow(group));
      if (group.isDir && _expanded.contains(group.path)) {
        for (final entry in group.items) {
          rows.add(_VisibleRow(group, entry: entry));
        }
      }
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: recentCount +
          (showRecent ? 1 : 0) +
          rows.length +
          1, // 末尾的状态行（正在加载 / 已全部加载）
      itemBuilder: (context, index) {
        if (showRecent && index == 0) {
          return const _SectionLabel('最近播放');
        }
        if (index < recentCount + (showRecent ? 1 : 0)) {
          final entry = _recent[index - 1];
          return LibraryRecentTile(
            entry: entry,
            onTap: () => unawaited(_openRecent(entry)),
          );
        }
        final rowIndex = index - recentCount - (showRecent ? 1 : 0);
        if (rowIndex >= rows.length) {
          return _footer();
        }
        final row = rows[rowIndex];
        final entry = row.entry;
        if (entry != null) {
          return LibraryTile(
            entry: entry,
            indent: true,
            onTap: () => unawaited(_open(entry)),
          );
        }
        final group = row.group;
        // 散放的单个视频直接排成一行，点开就播；只有文件夹才需要先展开。
        if (!group.isDir && group.items.isNotEmpty) {
          final video = group.items.first;
          return LibraryTile(
            entry: video,
            onTap: () => unawaited(_open(video)),
          );
        }
        return LibraryGroupTile(
          group: group,
          expanded: _expanded.contains(group.path),
          onTap: () => _toggle(group),
        );
      },
    );
  }

  /// 展开或收起一个文件夹。
  void _toggle(LibraryGroup group) {
    setState(() {
      if (!_expanded.remove(group.path)) _expanded.add(group.path);
    });
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_page.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: TextButton(
            onPressed: () => unawaited(_loadMore()),
            child: const Text('加载更多'),
          ),
        ),
      );
    }
    final total = _page.total;
    final videos = _page.videoTotal;
    // 收藏拢时就只报总数，免得「12 项 / 12 部」看着像多了一行废话。
    final text = _keyword.isNotEmpty
        ? '共 $total 项'
        : (videos > total ? '共 $total 项 · $videos 部视频' : '共 $total 项');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: PavlColors.textDim),
        ),
      ),
    );
  }
}

/// 列表里的一行：文件夹行，或展开后从属的那一集。
class _VisibleRow {
  _VisibleRow(this.group, {this.entry});

  final LibraryGroup group;

  /// 非空表示这是文件夹里的一集。
  final MediaEntry? entry;
}

/// 分组标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          color: PavlColors.textDim,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
