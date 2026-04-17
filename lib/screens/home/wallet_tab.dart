import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/connection_model.dart';
import '../../services/firestore_service.dart';
import '../../widgets/user_avatar.dart';

/// Tab Wallet: lista contatti scambiati con ricerca.
class WalletTab extends StatefulWidget {
  const WalletTab({super.key});

  @override
  State<WalletTab> createState() => _WalletTabState();
}

class _WalletTabState extends State<WalletTab> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
            decoration: InputDecoration(
              hintText: 'Cerca contatti...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        // Lista contatti
        Expanded(
          child: StreamBuilder<List<WalletContact>>(
            stream: FirestoreService.instance.listenToWallet(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final allContacts = snapshot.data ?? [];
              final contacts = _searchQuery.isEmpty
                  ? allContacts
                  : allContacts.where((c) {
                      final q = _searchQuery;
                      return c.fullName.toLowerCase().contains(q) ||
                          c.company.toLowerCase().contains(q) ||
                          c.role.toLowerCase().contains(q);
                    }).toList();

              if (allContacts.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.contacts_outlined,
                          size: 56,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text('Nessun contatto',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(
                        'I biglietti scambiati appariranno qui',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (contacts.isEmpty) {
                return Center(
                  child: Text(
                    'Nessun risultato per "$_searchQuery"',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: contacts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _ContactCard(
                  contact: contacts[i],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Contact Card ────────────────────────────────────────────

class _ContactCard extends StatelessWidget {
  final WalletContact contact;
  const _ContactCard({required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () => _showContactDetail(context),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            UserAvatar(
              imageUrl: contact.avatarURL,
              name: contact.fullName,
              size: 52,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.fullName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${contact.role} · ${contact.company}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (contact.eventName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      contact.eventName,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _showContactDetail(BuildContext context) {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),

              UserAvatar(
                imageUrl: contact.avatarURL,
                name: contact.fullName,
                size: 88,
                borderColor: theme.colorScheme.primary,
                borderWidth: 2.5,
              ),
              const SizedBox(height: 14),

              Text(
                contact.fullName,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${contact.role} · ${contact.company}',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              if (contact.eventName.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    contact.eventName,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              if (contact.email.isNotEmpty)
                _DetailRow(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: contact.email,
                ),
              if (contact.phone.isNotEmpty)
                _DetailRow(
                  icon: Icons.phone_outlined,
                  label: 'Telefono',
                  value: contact.phone,
                ),
              if (contact.linkedin.isNotEmpty)
                _DetailRow(
                  icon: Icons.link_outlined,
                  label: 'LinkedIn',
                  value: contact.linkedin,
                ),

              if (contact.note.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NOTE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(contact.note, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copiato'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            Icon(Icons.copy, size: 14,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
