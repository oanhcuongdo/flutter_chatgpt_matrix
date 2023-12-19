import 'package:aichat/utils/Chatgpt.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

class AIChatStore extends ChangeNotifier {
  late final String wordpressUrl;
  late final String wordpressApiEndpoint;

  final String username = 'beenet';

  AIChatStore() {
    wordpressUrl = 'https://beenet.vn/wp-json/wp/v2';
    wordpressApiEndpoint = '$wordpressUrl/posts';
    syncStorage();
  }

  String chatListKey = 'chatList';
  List chatList = [];

  get sortChatList {
    List sortList = chatList;
    sortList.sort((a, b) {
      return b['updatedTime'].compareTo(a['updatedTime']);
    });
    return sortList;
  }

  get homeHistoryList {
    return sortChatList.take(2).toList();
  }

  Map _createChat(String aiType, String chatId) {
    int timestamp = DateTime.now().millisecondsSinceEpoch;
    Map aiData = ChatGPT.getAiInfoByType(aiType);
    Map chat = {
      "id": chatId,
      "ai": {
        "type": aiData['type'],
        "name": aiData['name'],
        "isContinuous": aiData['isContinuous'],
        "continuesStartIndex": 0,
      },
      "systemMessage": {
        "role": "system",
        "content": aiData['content'],
      },
      "messages": [],
      "createdTime": timestamp,
      "updatedTime": timestamp,
    };

    return chat;
  }

  Future deleteChatById(String chatId) async {
    Map? cacheChat = chatList.firstWhere(
          (v) => v['id'] == chatId,
      orElse: () => null,
    );
    if (cacheChat != null) {
      chatList.removeWhere((v) => v['id'] == chatId);
      await ChatGPT.storage.write(chatListKey, chatList);
      notifyListeners();
    }
  }

  void syncStorage() {
    chatList = ChatGPT.storage.read(chatListKey) ?? [];
    debugPrint('---syncStorage success---');
    notifyListeners();
  }

  void fixChatList() {
    for (int i = 0; i < chatList.length; i++) {
      Map chat = chatList[i];
      for (int k = 0; k < chat['messages'].length; k++) {
        Map v = chat['messages'][k];
        if (v['role'] == 'generating') {
          chatList[i]['messages'][k] = {
            'role': 'error',
            'content': 'Request timeout',
          };
        }
      }
    }
    notifyListeners();
  }

  Map getChatById(String chatType, String chatId) {
    Map? chat = chatList.firstWhere(
          (v) => v['id'] == chatId,
      orElse: () => null,
    );

    if (chat == null) {
      return _createChat(chatType, chatId);
    }

    return chat;
  }

  Future<Map> pushMessage(Map chat, Map message) async {
    Map? cacheHistory = chatList.firstWhere(
          (v) => v['id'] == chat['id'],
      orElse: () => null,
    );
    int timestamp = DateTime.now().millisecondsSinceEpoch;
    if (cacheHistory != null) {
      chatList.removeWhere((v) => v['id'] == cacheHistory!['id']);
      cacheHistory['messages'].add(message);
      cacheHistory['updatedTime'] = timestamp;
      chatList.add(cacheHistory);

      await ChatGPT.storage.write(chatListKey, chatList);
      notifyListeners();

      await postNearestHistoryToWordPress();

      return cacheHistory;
    }

    cacheHistory = chat;
    cacheHistory['messages'].add(message);
    cacheHistory['updatedTime'] = timestamp;
    chatList.add(cacheHistory);
    await ChatGPT.storage.write(chatListKey, chatList);
    notifyListeners();
    print('---cacheHistory---$cacheHistory');
    return cacheHistory;
  }

  Future replaceMessage(String chatId, int messageIndex, Map message) async {
    Map? chat = chatList.firstWhere(
          (v) => v['id'] == chatId,
      orElse: () => null,
    );
    if (chat != null) {
      for (var i = 0; i < chatList.length; ++i) {
        Map v = chatList[i];
        if (v['id'] == chatId) {
          int timestamp = DateTime.now().millisecondsSinceEpoch;
          chatList[i]['messages'][messageIndex] = message;
          chatList[i]['updatedTime'] = timestamp;
          break;
        }
      }
      await ChatGPT.storage.write(chatListKey, chatList);
      notifyListeners();
    }
  }

  Future pushStreamMessage(String chatId, int messageIndex, Map message) async {
    if (chatId != '' && message['content'] != '' && message['content'] != null) {
      final index = chatList.indexWhere((v) => v['id'] == chatId);
      Map current = chatList[index]['messages'][messageIndex];

      if (current['role'] != message['role']) {
        chatList[index]['messages'][messageIndex] = message;
      } else {
        chatList[index]['messages'][messageIndex] = {
          "role": message['role'],
          "content": '${current['content']}${message['content']}',
        };
      }

      int timestamp = DateTime.now().millisecondsSinceEpoch;
      chatList[index]['updatedTime'] = timestamp;

      ChatGPT.storage.write(chatListKey, chatList);
      notifyListeners();
    }
  }

  Future<void> postNearestHistoryToWordPress() async {
    final nearestChat = sortChatList.isNotEmpty ? sortChatList.first : null;

    if (nearestChat != null) {
      final String title = '${nearestChat['ai']['name']} - ${_formatTimestamp(nearestChat['updatedTime'])}';
      final List<Map<String, String>> messages = List.from(nearestChat['messages'])
          .map<Map<String, String>>((message) => {'role': message['role'], 'content': message['content']})
          .toList();

      final Map<String, dynamic> postData = {
        'title': title,
        'content': _buildContentFromMessages(messages),
      };

      try {
        final http.Response response = await http.post(
          Uri.parse(wordpressApiEndpoint),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
          },
          body: jsonEncode(postData),
        );

        if (response.statusCode == 201) {
          print('Post to WordPress successful!');
          showToast('Post to WordPress successful!', ToastGravity.BOTTOM);
        } else {
          print('Failed to post to WordPress. Status code: ${response.statusCode}');
          print('Response body: ${response.body}');
          showToast('Failed to post to WordPress', ToastGravity.BOTTOM);
        }
      } catch (error) {
        print('Error posting to WordPress: $error');
        showToast('Error posting to WordPress', ToastGravity.BOTTOM);
      }
    } else {
      print('No chat history available to post.');
      showToast('No chat history available to post', ToastGravity.BOTTOM);
    }
  }

  String _formatTimestamp(int timestamp) {
    final DateTime dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dateTime.hour}-${dateTime.minute}-${dateTime.day}-${dateTime.month}-${dateTime.year}';
  }

  String _buildContentFromMessages(List<Map<String, String>> messages) {
    return messages.map<String>((message) => '[${message['role']}] ${message['content']}').join('\n');
  }

  void showToast(String message, ToastGravity gravity) {
    Fluttertoast.showToast(
      msg: message,
      gravity: gravity,
      timeInSecForIosWeb: 1,
      backgroundColor: Colors.black,
      textColor: Colors.white,
    );
  }
}
