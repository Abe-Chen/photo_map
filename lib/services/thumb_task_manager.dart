import 'dart:async';
import 'package:flutter/foundation.dart';

/// 缩略图任务取消令牌
class ThumbTaskToken<T> {
  final String key;
  final Completer<T> _completer;
  bool _isCancelled = false;
  
  ThumbTaskToken._(this.key, this._completer);
  
  /// 是否已取消
  bool get isCancelled => _isCancelled;
  
  /// 取消任务
  void cancel() {
    if (!_isCancelled) {
      _isCancelled = true;
      if (!_completer.isCompleted) {
        _completer.completeError(TaskCancelledException(key));
      }
    }
  }
  
  /// 获取任务结果
  Future<T> get future => _completer.future;
}

/// 任务取消异常
class TaskCancelledException implements Exception {
  final String key;
  TaskCancelledException(this.key);
  
  @override
  String toString() => 'Task cancelled: $key';
}

/// 缩略图任务管理器
class ThumbTaskManager {
  final int maxConcurrent;
  
  // 正在运行的任务
  final Map<String, ThumbTaskToken> _runningTasks = {};
  
  // 等待队列
  final List<_QueuedTask> _waitingQueue = [];
  
  ThumbTaskManager({this.maxConcurrent = 4});
  
  /// 调度任务
  /// [key] 任务唯一标识
  /// [futureFactory] 任务工厂函数
  /// 返回可取消的token
  ThumbTaskToken<T> schedule<T>(String key, Future<T> Function() futureFactory) {
    // 如果已有相同key的任务在运行，直接返回现有token
    if (_runningTasks.containsKey(key)) {
      return _runningTasks[key]! as ThumbTaskToken<T>;
    }
    
    // 创建新的token
    final completer = Completer<T>();
    final token = ThumbTaskToken<T>._(key, completer);
    
    // 如果当前运行任务数未达到上限，立即执行
    if (_runningTasks.length < maxConcurrent) {
      _executeTask(key, token, futureFactory);
    } else {
      // 否则加入等待队列
      _waitingQueue.add(_QueuedTask(key, token, futureFactory));
    }
    
    return token;
  }
  
  /// 取消指定key的任务
  void cancelTask(String key) {
    // 取消正在运行的任务
    final runningToken = _runningTasks[key];
    if (runningToken != null) {
      runningToken.cancel();
      _runningTasks.remove(key);
      _processWaitingQueue();
      return;
    }
    
    // 取消等待队列中的任务
    _waitingQueue.removeWhere((task) {
      if (task.key == key) {
        task.token.cancel();
        return true;
      }
      return false;
    });
  }
  
  /// 取消所有不在指定集合中的任务
  void cancelTasksNotIn(Set<String> keepKeys) {
    // 取消正在运行的任务
    final toRemove = <String>[];
    _runningTasks.forEach((key, token) {
      if (!keepKeys.contains(key)) {
        token.cancel();
        toRemove.add(key);
      }
    });
    
    for (final key in toRemove) {
      _runningTasks.remove(key);
    }
    
    // 取消等待队列中的任务
    _waitingQueue.removeWhere((task) {
      if (!keepKeys.contains(task.key)) {
        task.token.cancel();
        return true;
      }
      return false;
    });
    
    // 处理等待队列
    _processWaitingQueue();
  }
  
  /// 取消所有任务
  void cancelAllTasks() {
    // 取消所有正在运行的任务
    _runningTasks.values.forEach((token) => token.cancel());
    _runningTasks.clear();
    
    // 取消所有等待中的任务
    _waitingQueue.forEach((task) => task.token.cancel());
    _waitingQueue.clear();
  }
  
  /// 执行任务
  void _executeTask<T>(String key, ThumbTaskToken<T> token, Future<T> Function() futureFactory) {
    _runningTasks[key] = token;
    
    // 异步执行任务
    futureFactory().then((result) {
      if (!token.isCancelled) {
        token._completer.complete(result);
      }
    }).catchError((error) {
      if (!token.isCancelled) {
        token._completer.completeError(error);
      }
    }).whenComplete(() {
      // 任务完成后清理并处理等待队列
      _runningTasks.remove(key);
      _processWaitingQueue();
    });
  }
  
  /// 处理等待队列
  void _processWaitingQueue() {
    while (_waitingQueue.isNotEmpty && _runningTasks.length < maxConcurrent) {
      final task = _waitingQueue.removeAt(0);
      if (!task.token.isCancelled) {
        _executeTask(task.key, task.token, task.futureFactory);
      }
    }
  }
  
  /// 获取管理器状态
  Map<String, dynamic> getStats() {
    return {
      'runningTasks': _runningTasks.length,
      'waitingTasks': _waitingQueue.length,
      'maxConcurrent': maxConcurrent,
      'runningKeys': _runningTasks.keys.toList(),
      'waitingKeys': _waitingQueue.map((task) => task.key).toList(),
    };
  }
}

/// 等待队列中的任务
class _QueuedTask {
  final String key;
  final ThumbTaskToken token;
  final Future Function() futureFactory;
  
  _QueuedTask(this.key, this.token, this.futureFactory);
}