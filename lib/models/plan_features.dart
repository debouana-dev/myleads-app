/// Canonical subscription plan identifiers.
enum SubscriptionPlan { free, premium, business }

/// Feature limits and capabilities derived from a user's subscription plan.
///
/// All properties are computed from [plan] so a single [PlanFeatures.fromString]
/// call gives the full feature set for any plan string stored in the database.
class PlanFeatures {
  final SubscriptionPlan plan;
  const PlanFeatures._(this.plan);

  static const PlanFeatures free = PlanFeatures._(SubscriptionPlan.free);
  static const PlanFeatures premium = PlanFeatures._(SubscriptionPlan.premium);
  static const PlanFeatures business =
      PlanFeatures._(SubscriptionPlan.business);

  static PlanFeatures fromString(String? s) {
    switch (s) {
      case 'premium':
        return premium;
      case 'business':
        return business;
      default:
        return free;
    }
  }

  /// The canonical string stored in the database (matches [SubscriptionPlan.name]).
  String get id => plan.name;

  // ── Contact limits ──────────────────────────────────────────────────────────
  /// Maximum number of contacts. -1 = unlimited.
  int get maxContacts => plan == SubscriptionPlan.free ? 10 : -1;
  bool get hasUnlimitedContacts => maxContacts == -1;

  // ── Reminder limits ─────────────────────────────────────────────────────────
  /// Maximum number of active (non-completed) reminders. -1 = unlimited.
  int get maxActiveReminders => plan == SubscriptionPlan.free ? 5 : -1;
  bool get hasUnlimitedReminders => maxActiveReminders == -1;

  // ── Scan capabilities ───────────────────────────────────────────────────────
  bool get hasCardScan => true; // all plans
  bool get hasQrScan => plan != SubscriptionPlan.free;
  bool get hasNfcScan => plan != SubscriptionPlan.free;

  // ── Import / Export ─────────────────────────────────────────────────────────
  bool get hasExport => plan != SubscriptionPlan.free;
  bool get hasImport => true;

  // ── Cloud & AI enrichment ───────────────────────────────────────────────────
  bool get hasCloudSync => plan != SubscriptionPlan.free;
  bool get hasAiEnrichment => plan != SubscriptionPlan.free;

  // ── Team / Organization (Business only) ─────────────────────────────────────
  bool get hasOrganization => plan == SubscriptionPlan.business;
  bool get hasTeamDashboard => plan == SubscriptionPlan.business;
  bool get hasApiAccess => plan == SubscriptionPlan.business;
  bool get hasAdvancedAnalytics => plan == SubscriptionPlan.business;
  bool get hasAiLeadScoring => plan == SubscriptionPlan.business;
}
