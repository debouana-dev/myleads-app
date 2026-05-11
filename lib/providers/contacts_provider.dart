import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/interaction.dart';
import '../models/plan_features.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

/// Result of a contact mutation. [error] is null on success.
class ContactResult {
  final Contact? contact;
  final String? error;
  const ContactResult.success(this.contact) : error = null;
  const ContactResult.failure(this.error) : contact = null;
  bool get isSuccess => error == null;
}

// Sentinel object used to distinguish "not provided" from an explicit null
// in copyWith (so we can clear statusFilter by passing null).
const Object _sentinel = Object();

class ContactsState {
  final List<Contact> contacts;
  final String searchQuery;
  final String activeFilter;
  final String? statusFilter;
  final bool isLoading;

  const ContactsState({
    this.contacts = const [],
    this.searchQuery = '',
    this.activeFilter = 'all',
    this.statusFilter,
    this.isLoading = false,
  });

  /// Returns contacts filtered by search query (name, company, role) AND
  /// the active status/tag filter. Sorted hot → warm → cold then by date.
  List<Contact> get filteredContacts {
    var filtered = List<Contact>.from(contacts);

    // Status / tag filter
    if (activeFilter != 'all') {
      filtered = filtered.where((c) {
        if (c.status == activeFilter) return true;
        return c.tags.any((t) => t.toLowerCase() == activeFilter.toLowerCase());
      }).toList();
    }

    // Status filter (setStatusFilter)
    if (statusFilter != null) {
      filtered = filtered.where((c) => c.status == statusFilter).toList();
    }

    // Search by name, company, or job title (role)
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      filtered = filtered.where((c) {
        return c.firstName.toLowerCase().contains(q) ||
            c.lastName.toLowerCase().contains(q) ||
            c.fullName.toLowerCase().contains(q) ||
            (c.company?.toLowerCase().contains(q) ?? false) ||
            (c.jobTitle?.toLowerCase().contains(q) ?? false);
      }).toList();
    }

    filtered.sort((a, b) {
      const priority = {'hot': 0, 'warm': 1, 'cold': 2};
      final cmp = (priority[a.status] ?? 2).compareTo(priority[b.status] ?? 2);
      if (cmp != 0) return cmp;
      return b.createdAt.compareTo(a.createdAt);
    });

    return filtered;
  }

  int get totalContacts => contacts.length;
  int get hotLeads => contacts.where((c) => c.status == 'hot').length;
  int get warmLeads => contacts.where((c) => c.status == 'warm').length;
  int get coldLeads => contacts.where((c) => c.status == 'cold').length;

  ContactsState copyWith({
    List<Contact>? contacts,
    String? searchQuery,
    String? activeFilter,
    Object? statusFilter = _sentinel,
    bool? isLoading,
  }) {
    return ContactsState(
      contacts: contacts ?? this.contacts,
      searchQuery: searchQuery ?? this.searchQuery,
      activeFilter: activeFilter ?? this.activeFilter,
      statusFilter: statusFilter == _sentinel
          ? this.statusFilter
          : statusFilter as String?,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class ContactsNotifier extends StateNotifier<ContactsState> {
  ContactsNotifier() : super(const ContactsState()) {
    _loadContacts().then((_) async {
      _lastSyncAt = await DatabaseService.getUserLastSync(_ownerId);
      _syncCheckTimer = Timer.periodic(
          const Duration(seconds: 30), (_) => _checkForSyncUpdate());
    });
  }

  Timer? _syncCheckTimer;
  String? _lastSyncAt;

  String get _ownerId => StorageService.currentUserId;

  Future<void> _loadContacts() async {
    state = state.copyWith(isLoading: true);
    if (_ownerId.isEmpty) {
      state = state.copyWith(contacts: [], isLoading: false);
      return;
    }
    final user = StorageService.currentUser;
    List<Contact> contacts;
    if (user?.organizationId != null) {
      final orgActive =
          await DatabaseService.isOrganizationActive(user!.organizationId!);
      if (orgActive) {
        // Suspended members see only their own contacts (which includes any
        // duplicate contacts that were not transferred to admin on suspension).
        final memberStatus = await DatabaseService.getMemberStatus(
          userId: _ownerId,
          orgId: user.organizationId!,
        );
        if (memberStatus == 'suspended') {
          contacts = await StorageService.getAllContacts();
        } else {
          contacts = await DatabaseService.getAllContactsForOrganization(
              user.organizationId!);
        }
      } else {
        // Org is expired/suspended; fall back to the user's personal contact set.
        contacts = await StorageService.getAllContacts();
      }
    } else {
      contacts = await StorageService.getAllContacts();
    }

    final effectivePlan = await StorageService.getEffectivePlan();
    if (effectivePlan == 'free') {
      contacts = contacts.take(PlanFeatures.free.maxContacts).toList();
    }

    state = state.copyWith(contacts: contacts, isLoading: false);
  }

  /// Reloads contacts from disk (call after login).
  Future<void> reload() => _loadContacts();

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void setFilter(String filter) {
    state = state.copyWith(activeFilter: filter);
  }

  /// Filters the contacts list to only show contacts with [filter] status.
  /// Pass null to clear the filter and show all statuses.
  void setStatusFilter(String? filter) {
    state = state.copyWith(statusFilter: filter);
  }

  // ============== VALIDATION ==============

  /// Validates a contact against business rules:
  /// - last name required
  /// - phone OR email required
  /// - no duplicate phone/email for the same owner
  /// - no contact with same first+last+(phone or email)
  String? _validateContact(Contact c) {
    if (c.lastName.trim().isEmpty) {
      return 'Le nom de famille est obligatoire';
    }
    final hasPhone = c.phone != null && c.phone!.trim().isNotEmpty;
    final hasEmail = c.email != null && c.email!.trim().isNotEmpty;
    if (!hasPhone && !hasEmail) {
      return 'Au moins un numéro de téléphone ou un email est requis';
    }
    return null;
  }

  // ============== CRUD ==============

  static const String freeContactLimitError = 'free_contact_limit_reached';

  Future<ContactResult> addContact(Contact contact) async {
    final user = StorageService.currentUser;
    final ownerId = _ownerId;
    if (ownerId.isEmpty) {
      return const ContactResult.failure('Vous devez être connecté');
    }

    final effectivePlan = await StorageService.getEffectivePlan();
    final planFeatures = PlanFeatures.fromString(effectivePlan);
    if (!planFeatures.hasUnlimitedContacts &&
        state.contacts.length >= planFeatures.maxContacts) {
      return const ContactResult.failure(freeContactLimitError);
    }

    // Privilege check: can this user create contacts?
    final canCreate = await DatabaseService.canUserCreateContact(
      userId: ownerId,
      orgId: user?.organizationId,
    );
    if (!canCreate) {
      return const ContactResult.failure(
          "Vous n'avez pas les droits pour créer des contacts");
    }

    final newContact = contact.copyWith(id: _uuid.v4(), ownerId: ownerId);

    final validationErr = _validateContact(newContact);
    if (validationErr != null) return ContactResult.failure(validationErr);

    final conflict = await DatabaseService.findContactConflict(
      ownerId: ownerId,
      phone: newContact.phone,
      email: newContact.email,
    );
    if (conflict != null) return ContactResult.failure(conflict);

    final identical = await DatabaseService.hasIdenticalContact(
      ownerId: ownerId,
      firstName: newContact.firstName,
      lastName: newContact.lastName,
      phone: newContact.phone,
      email: newContact.email,
    );
    if (identical) {
      return const ContactResult.failure(
          'Un contact identique (même nom et coordonnées) existe déjà');
    }

    await DatabaseService.insertContact(newContact);
    state = state.copyWith(contacts: [...state.contacts, newContact]);
    if (newContact.status == 'hot' || newContact.status == 'warm') {
      NotificationService.createIncompleteContactNotification(newContact);
    }
    return ContactResult.success(newContact);
  }

  Future<ContactResult> updateContact(Contact contact) async {
    final user = StorageService.currentUser;
    final ownerId = _ownerId;
    if (ownerId.isEmpty) {
      return const ContactResult.failure('Vous devez être connecté');
    }

    // Privilege check: owner can always edit their own; org admin / can_edit can edit others'.
    final canEdit = await DatabaseService.canUserEditContact(
      userId: ownerId,
      orgId: user?.organizationId,
      contactOwnerId: contact.ownerId,
    );
    if (!canEdit) {
      return const ContactResult.failure(
          "Vous n'avez pas les droits pour modifier ce contact");
    }

    // Preserve the contact's original ownerId — never change ownership on edit.
    final updated = contact;
    final validationErr = _validateContact(updated);
    if (validationErr != null) return ContactResult.failure(validationErr);

    final conflict = await DatabaseService.findContactConflict(
      ownerId: contact.ownerId, // use original owner for conflict scope
      phone: updated.phone,
      email: updated.email,
      excludeId: updated.id,
    );
    if (conflict != null) return ContactResult.failure(conflict);

    final identical = await DatabaseService.hasIdenticalContact(
      ownerId: contact.ownerId, // scope to original owner
      firstName: updated.firstName,
      lastName: updated.lastName,
      phone: updated.phone,
      email: updated.email,
      excludeId: updated.id,
    );
    if (identical) {
      return const ContactResult.failure(
          'Un contact identique (même nom et coordonnées) existe déjà');
    }

    // Capture previous version for diff/audit logging.
    Contact? previous;
    try {
      previous = state.contacts.firstWhere((c) => c.id == updated.id);
    } catch (_) {
      previous = null;
    }

    await DatabaseService.updateContact(updated);
    final list =
        state.contacts.map((c) => c.id == updated.id ? updated : c).toList();
    state = state.copyWith(contacts: list);

    if (updated.status == 'hot' || updated.status == 'warm') {
      NotificationService.createIncompleteContactNotification(updated);
    }

    if (previous != null) {
      final diff = _diffContact(previous, updated);
      if (diff.isNotEmpty) {
        try {
          await DatabaseService.insertInteraction(Interaction(
            id: _uuid.v4(),
            ownerId: ownerId,
            contactId: updated.id,
            type: 'edit',
            content: 'Contact modifié: ${diff.join(' · ')}',
          ));
        } catch (_) {}
      }
    }

    return ContactResult.success(updated);
  }

  /// Produces a human-readable list of field-level changes between two
  /// [Contact] revisions, used for the audit interaction entry.
  List<String> _diffContact(Contact a, Contact b) {
    final out = <String>[];
    void diff(String label, Object? ov, Object? nv) {
      final ox = (ov is String) ? ov.trim() : ov;
      final nx = (nv is String) ? nv.trim() : nv;
      if ('$ox' == '$nx') return;
      out.add(label);
    }

    diff('prénom', a.firstName, b.firstName);
    diff('nom', a.lastName, b.lastName);
    diff('fonction', a.jobTitle, b.jobTitle);
    diff('société', a.company, b.company);
    diff('téléphone', a.phone, b.phone);
    diff('email', a.email, b.email);
    diff('source', a.source, b.source);
    diff('projet 1', a.project1, b.project1);
    diff('budget 1', a.project1Budget, b.project1Budget);
    diff('projet 2', a.project2, b.project2);
    diff('budget 2', a.project2Budget, b.project2Budget);
    diff('notes', a.notes, b.notes);
    diff('statut', a.status, b.status);
    diff('tags', a.tags.join(','), b.tags.join(','));
    return out;
  }

  Future<String?> deleteContact(String id) async {
    final user = StorageService.currentUser;
    final ownerId = _ownerId;

    // Find the contact to check ownership.
    Contact? target;
    try {
      target = state.contacts.firstWhere((c) => c.id == id);
    } catch (_) {}

    if (target != null) {
      final canEdit = await DatabaseService.canUserEditContact(
        userId: ownerId,
        orgId: user?.organizationId,
        contactOwnerId: target.ownerId,
      );
      if (!canEdit) {
        return "Vous n'avez pas les droits pour supprimer ce contact";
      }
    }

    await DatabaseService.deleteContact(id);
    state = state.copyWith(
      contacts: state.contacts.where((c) => c.id != id).toList(),
    );
    return null;
  }

  Future<void> addInteraction(Interaction interaction) async {
    final ownerId = _ownerId;
    final i = interaction.ownerId.isEmpty
        ? Interaction(
            id: interaction.id,
            ownerId: ownerId,
            contactId: interaction.contactId,
            type: interaction.type,
            content: interaction.content,
            createdAt: interaction.createdAt,
          )
        : interaction;
    await DatabaseService.insertInteraction(i);
    final contact = state.contacts.firstWhere(
      (c) => c.id == i.contactId,
      orElse: () => throw Exception('Contact not found'),
    );
    await updateContact(
      contact.copyWith(lastContactDate: DateTime.now()),
    );
  }

  Future<List<Interaction>> getInteractions(String contactId) {
    return DatabaseService.getInteractionsForContact(contactId);
  }

  Future<void> _checkForSyncUpdate() async {
    if (_ownerId.isEmpty) return;
    final currentSyncAt = await DatabaseService.getUserLastSync(_ownerId);
    if (currentSyncAt != null && currentSyncAt != _lastSyncAt) {
      _lastSyncAt = currentSyncAt;
      await _loadContacts();
    }
  }

  @override
  void dispose() {
    _syncCheckTimer?.cancel();
    super.dispose();
  }
}

final contactsProvider =
    StateNotifierProvider<ContactsNotifier, ContactsState>((ref) {
  return ContactsNotifier();
});

// Derived providers
final hotLeadsProvider = Provider<List<Contact>>((ref) {
  final contacts = ref.watch(contactsProvider).contacts;
  return contacts.where((c) => c.status == 'hot').toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
});

final contactByIdProvider = Provider.family<Contact?, String>((ref, id) {
  final contacts = ref.watch(contactsProvider).contacts;
  try {
    return contacts.firstWhere((c) => c.id == id);
  } catch (_) {
    return null;
  }
});
