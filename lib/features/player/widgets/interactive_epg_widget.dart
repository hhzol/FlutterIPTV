import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../../core/models/channel.dart';
import '../../../core/services/epg_service.dart';
import '../../epg/providers/epg_provider.dart';
import '../../../core/theme/app_theme.dart';

class InteractiveEpgWidget extends StatefulWidget {
  final Channel channel;
  final Function(EpgProgram) onProgramSelected;
  final VoidCallback onBackToLive;
  final bool isPlayingCatchup;
  final EpgProgram? currentCatchupProgram;

  const InteractiveEpgWidget({
    super.key,
    required this.channel,
    required this.onProgramSelected,
    required this.onBackToLive,
    this.isPlayingCatchup = false,
    this.currentCatchupProgram,
  });

  @override
  State<InteractiveEpgWidget> createState() => _InteractiveEpgWidgetState();
}

class _InteractiveEpgWidgetState extends State<InteractiveEpgWidget> {
  late DateTime _selectedDate;
  final ScrollController _dateScrollController = ScrollController();
  final ScrollController _programScrollController = ScrollController();
  bool _hasInitialScrolled = false;

  @override
  void initState() {
    super.initState();
    if (widget.isPlayingCatchup && widget.currentCatchupProgram != null) {
      _selectedDate = widget.currentCatchupProgram!.start;
    } else {
      _selectedDate = DateTime.now();
    }
  }

  @override
  void didUpdateWidget(InteractiveEpgWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel.id != widget.channel.id) {
      _hasInitialScrolled = false;
    }
  }

  @override
  void dispose() {
    _dateScrollController.dispose();
    _programScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: 800,
        color: Colors.black.withOpacity(0.85),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                widget.channel.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            // Back to Live button
            if (widget.isPlayingCatchup)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: ElevatedButton.icon(
                  onPressed: widget.onBackToLive,
                  icon: const Icon(Icons.live_tv),
                  label: const Text('回到直播 (Back to Live)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),

            // Date Selector
            SizedBox(
              height: 60,
              child: ListView.builder(
                controller: _dateScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: 8,
                itemBuilder: (context, index) {
                  final date = DateTime.now().add(Duration(days: index - 5));
                  final isSelected = _isSameDay(date, _selectedDate);
                  final isToday = _isSameDay(date, DateTime.now());

                  return InkWell(
                    onTap: () {
                      setState(() {
                        _selectedDate = date;
                      });
                    },
                    child: Container(
                      width: 80,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: isSelected ? AppTheme.primaryColor : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        color: isSelected ? AppTheme.primaryColor.withOpacity(0.2) : Colors.transparent,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isToday ? '今天' : DateFormat('MM-dd').format(date),
                            style: TextStyle(
                              color: isSelected ? AppTheme.primaryColor : Colors.white70,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          Text(
                            _getWeekday(date),
                            style: TextStyle(
                              color: isSelected ? AppTheme.primaryColor : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const Divider(height: 1, color: Colors.white24),

            // Program List
            Expanded(
              child: Consumer<EpgProvider>(
                builder: (context, epgProvider, child) {
                  final programs = epgProvider.getProgramsForDate(
                    widget.channel.epgId ?? widget.channel.name,
                    widget.channel.name,
                    _selectedDate,
                  );

                  if (programs.isEmpty) {
                    return const Center(
                      child: Text(
                        '暂无节目单',
                        style: TextStyle(color: Colors.white54),
                      ),
                    );
                  }

                  if (!_hasInitialScrolled) {
                    _hasInitialScrolled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!_programScrollController.hasClients) return;

                      int targetIndex = -1;

                      if (widget.isPlayingCatchup && widget.currentCatchupProgram != null) {
                        targetIndex = programs.indexWhere((p) =>
                            p.start == widget.currentCatchupProgram!.start &&
                            p.title == widget.currentCatchupProgram!.title);
                      } else {
                        final now = DateTime.now();
                        targetIndex = programs.indexWhere((p) =>
                            now.isAfter(p.start) && now.isBefore(p.end));

                        if (targetIndex == -1) {
                          targetIndex = programs
                              .lastIndexWhere((p) => p.end.isBefore(now));
                        }
                      }

                      if (targetIndex >= 0) {
                        final offset = targetIndex * 72.0;
                        final maxScroll = _programScrollController.position.maxScrollExtent;
                        final targetScroll = offset > maxScroll ? maxScroll : offset;
                        _programScrollController.jumpTo(targetScroll);
                      }
                    });
                  }

                  return ListView.builder(
                    controller: _programScrollController,
                    itemExtent: 72.0,
                    itemCount: programs.length,
                    itemBuilder: (context, index) {
                      final program = programs[index];
                      final status = _getProgramStatus(program);
                      final isLive = status == ProgramStatus.live;
                      final isPast = status == ProgramStatus.past;

                      final canCatchup = isPast &&
                          widget.channel.hasCatchup &&
                          _isWithinCatchupRange(program);

                      // ============================================================
                      // MODIFIED: 只有当前正在播放的节目（直播或回放）才高亮
                      // ============================================================
                      final isPlayingThisCatchup = widget.isPlayingCatchup &&
                          widget.currentCatchupProgram != null &&
                          program.start == widget.currentCatchupProgram!.start &&
                          program.title == widget.currentCatchupProgram!.title;

                      final shouldHighlight = isLive || isPlayingThisCatchup;

                      return InkWell(
                        onTap: canCatchup ? () => widget.onProgramSelected(program) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          // MODIFIED: 只有 shouldHighlight 为 true 时才应用背景色
                          color: shouldHighlight
                              ? AppTheme.primaryColor.withOpacity(0.2)
                              : null,
                          child: Row(
                            children: [
                              // Time
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DateFormat('HH:mm').format(program.start),
                                    style: TextStyle(
                                      color: isLive ? AppTheme.primaryColor : Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    DateFormat('HH:mm').format(program.end),
                                    style: TextStyle(
                                      color: isLive
                                          ? AppTheme.primaryColor.withOpacity(0.7)
                                          : Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 16),

                              // Title & Status
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      program.title,
                                      style: TextStyle(
                                        // MODIFIED: 标题颜色同样只对高亮节目使用 primaryColor
                                        color: shouldHighlight
                                            ? AppTheme.primaryColor
                                            : Colors.white,
                                        fontSize: 15,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (program.description != null &&
                                        program.description!.isNotEmpty)
                                      Text(
                                        program.description!,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),

                              // Status Indicator
                              if (isLive)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    '直播',
                                    style: TextStyle(color: Colors.white, fontSize: 10),
                                  ),
                                )
                              else if (canCatchup)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryColor.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: AppTheme.primaryColor, width: 1),
                                  ),
                                  child: const Text(
                                    '回放',
                                    style: TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              else if (!isPast)
                                const Text(
                                  '即将播放',
                                  style: TextStyle(color: Colors.white30, fontSize: 10),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _getWeekday(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return weekdays[date.weekday - 1];
  }

  ProgramStatus _getProgramStatus(EpgProgram program) {
    final now = DateTime.now();
    if (now.isAfter(program.start) && now.isBefore(program.end)) {
      return ProgramStatus.live;
    } else if (now.isAfter(program.end)) {
      return ProgramStatus.past;
    } else {
      return ProgramStatus.future;
    }
  }

  bool _isWithinCatchupRange(EpgProgram program) {
    if (widget.channel.catchupDays == null) {
      return true;
    }
    final diff = DateTime.now().difference(program.start).inDays;
    return diff <= widget.channel.catchupDays!;
  }
}

enum ProgramStatus {
  past,
  live,
  future,
}
