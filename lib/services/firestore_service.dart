import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:flutter/foundation.dart';

class FirestoreService {
  static final FirestoreService _instance = FirestoreService._internal();

  factory FirestoreService() {
    return _instance;
  }

  FirestoreService._internal();

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  String? get _userId => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? get _conversationsCollection {
    final uid = _userId;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('conversations');
  }

  Future<List<ServerConversation>> getConversations({
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) async {
    final collection = _conversationsCollection;
    if (collection == null) return [];

    try {
      Query<Map<String, dynamic>> query = collection
          .orderBy('created_at', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id; // Ensure ID is set
        return ServerConversation.fromJson(data);
      }).toList();
    } catch (e) {
      debugPrint('Error getting conversations from Firestore: $e');
      return [];
    }
  }

  Future<void> saveConversation(ServerConversation conversation) async {
    final collection = _conversationsCollection;
    if (collection == null) return;

    try {
      await collection.doc(conversation.id).set(conversation.toJson());
      debugPrint('Saved conversation ${conversation.id} to Firestore');
    } catch (e) {
      debugPrint('Error saving conversation to Firestore: $e');
    }
  }

  Future<void> deleteConversation(String conversationId) async {
    final collection = _conversationsCollection;
    if (collection == null) return;

    try {
      await collection.doc(conversationId).delete();
      debugPrint('Deleted conversation $conversationId from Firestore');
    } catch (e) {
      debugPrint('Error deleting conversation from Firestore: $e');
    }
  }
}
