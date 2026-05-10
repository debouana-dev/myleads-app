import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/organization_provider.dart';
import '../../services/contact_actions.dart';
import '../../services/photo_storage_service.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final state = ref.watch(contactsProvider);
    final contacts = state.filteredContacts;
    final canCreate = ref.watch(orgCanCreateProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // Header
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 10,
              left: 24,
              right: 24,
              bottom: 24,
            ),
            decoration: const BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.contactsCount(state.totalContacts),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (canCreate)
                      GestureDetector(
                        onTap: () => context.push('/contact/new'),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.add,
                              color: Colors.white, size: 22),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // Search Bar
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderColor(context)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search,
                          color: AppColors.textLight, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          onChanged: (v) => ref
                              .read(contactsProvider.notifier)
                              .setSearchQuery(v),
                          style: const TextStyle(
                              color: Colors.black, fontSize: 14),
                          cursorColor: AppColors.primary,
                          decoration: InputDecoration(
                            hintText: l10n.searchContact,
                            hintStyle: const TextStyle(
                              color: AppColors.textLight,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Filter Chips
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              children: [
                _buildChip(context, ref, l10n.all, 'all', state.activeFilter),
                _buildChip(context, ref, 'Hot', 'hot', state.activeFilter),
                _buildChip(context, ref, 'Warm', 'warm', state.activeFilter),
                _buildChip(context, ref, 'Cold', 'cold', state.activeFilter),
                _buildChip(context, ref, 'Tech', 'tech', state.activeFilter),
                _buildChip(context, ref, 'Event', 'event', state.activeFilter),
              ],
            ),
          ),

          // Contacts List
          Expanded(
            child: contacts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_search,
                            size: 64,
                            color: AppColors.hint(context).withOpacity(0.4)),
                        const SizedBox(height: 16),
                        Text(
                          l10n.noContactFound,
                          style: TextStyle(
                            color: AppColors.secondary(context),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.read(contactsProvider.notifier).reload(),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 100),
                      itemCount: contacts.length,
                      itemBuilder: (context, index) {
                        return _buildContactItem(context, contacts[index]);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(BuildContext context, WidgetRef ref, String label,
      String value, String active) {
    final isActive = active == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => ref.read(contactsProvider.notifier).setFilter(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: BoxDecoration(
            color:
                isActive ? AppColors.primary : AppColors.surfaceColor(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  isActive ? AppColors.primary : AppColors.borderColor(context),
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.white : AppColors.secondary(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContactItem(BuildContext ctx, Contact contact) {
    final color = contact.avatarColor != null
        ? Color(int.parse(contact.avatarColor!))
        : AppColors.primary;

    return GestureDetector(
      onTap: () => ctx.push('/contact/${contact.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceColor(ctx),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color, color.withOpacity(0.7)],
                ),
                borderRadius: BorderRadius.circular(14),
                image: contact.photoPath != null && !kIsWeb
                    ? DecorationImage(
                        image: FileImage(File(
                            PhotoStorageService.resolveAbsolutePath(
                                contact.photoPath)!)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: contact.photoPath == null || kIsWeb
                  ? Center(
                      child: Text(
                        contact.initials,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.fullName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface(ctx),
                    ),
                  ),
                  if (contact.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      contact.subtitle,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.secondary(ctx)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildStatusBadge(contact.status),
                      ...contact.tags.take(2).map((t) => Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                t,
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          )),
                    ],
                  ),
                ],
              ),
            ),

            // Quick actions — Call + SMS only (per doc v7 spec).
            // WhatsApp lives on the contact detail screen; the list
            // card stays minimal.
            Column(
              children: [
                _buildMiniAction(
                  Icons.phone_rounded,
                  AppColors.success,
                  () => ContactActions.call(ctx, contact),
                ),
                const SizedBox(height: 6),
                _buildMiniAction(
                  Icons.sms_rounded,
                  AppColors.warm,
                  () => ContactActions.sms(ctx, contact),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color color;
    String label;
    switch (status) {
      case 'hot':
        color = AppColors.hot;
        label = 'HOT';
        break;
      case 'warm':
        color = AppColors.warm;
        label = 'WARM';
        break;
      default:
        color = AppColors.cold;
        label = 'COLD';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildMiniAction(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }
}
