import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';

/// Bilingual (FR / EN) string accessor.
///
/// Usage in any ConsumerWidget / ConsumerStatefulWidget:
///   final l10n = ref.watch(l10nProvider);
///   Text(l10n.login)
class AppL10n {
  final bool _en;
  const AppL10n(this._en);

  bool get isEnglish => _en;

  // ─── App ────────────────────────────────────────────────────────────────
  String get appName => 'Me2Leads';
  String get slogan =>
      _en ? 'Scan. Connect. Convert.' : 'Scannez. Connectez. Convertissez.';
  String get pitchShort => _en
      ? 'Turn every professional encounter into an opportunity. Scan a card, a QR code or a professional profile and instantly contact your leads.'
      : 'Transformez chaque rencontre professionnelle en opportunité. Scannez une carte, un QR code ou un profil professionnel et contactez instantanément vos leads.';

  // ─── Navigation ──────────────────────────────────────────────────────────
  String get navHome => _en ? 'Home' : 'Accueil';
  String get navContacts => 'Contacts';
  String get navReminders => _en ? 'Reminders' : 'Rappels';
  String get navAccount => _en ? 'Account' : 'Compte';

  // ─── Splash ──────────────────────────────────────────────────────────────
  String get splashTagline =>
      _en ? 'Scan. Connect. Convert.' : 'Scannez. Connectez. Convertissez.';

  // ─── Home ────────────────────────────────────────────────────────────────
  String get hello => _en ? 'Hello' : 'Bonjour';
  String get searchContact =>
      _en ? 'Search a contact...' : 'Rechercher un contact...';
  String get scanContact => _en ? 'Scan a contact' : 'Scanner un contact';
  String get addManually => _en ? 'Add manually' : 'Ajouter manuellement';
  String get hotLeads => _en ? 'Hot Leads' : 'Leads chauds';
  String get reminders => _en ? 'Reminders' : 'Rappels';
  String get viewAll => _en ? 'View all' : 'Voir tout';
  String get contacts => 'Contacts';
  String get today => _en ? 'Today' : "Aujourd'hui";
  String get overdue => _en ? 'Overdue' : 'En retard';
  String get done => _en ? 'Done' : 'Terminés';
  String get noHotLeads =>
      _en ? 'No hot leads yet' : 'Aucun lead chaud pour le moment';

  // ─── Auth – Common ───────────────────────────────────────────────────────
  String get emailLabel => _en ? 'Email' : 'Email';
  String get emailHint => 'votre@email.com';
  String get passwordLabel => _en ? 'Password' : 'Mot de passe';
  String get passwordHint => '••••••••';
  String get orContinueWith => _en ? 'or continue with' : 'ou continuer avec';

  // Validators
  String get emailRequired =>
      _en ? 'Please enter your email' : 'Veuillez entrer votre email';
  String get emailInvalid => _en ? 'Invalid email' : 'Email invalide';
  String get passwordRequired =>
      _en ? 'Please enter your password' : 'Veuillez entrer votre mot de passe';
  String get passwordLengthError => _en
      ? 'Password must be 8-15 characters'
      : 'Le mot de passe doit contenir entre 8 et 15 caractères';
  String get passwordNoSpaces => _en
      ? 'Password must not contain spaces'
      : "Le mot de passe ne doit pas contenir d'espaces";
  String get passwordNeedsLetter => _en
      ? 'Password must contain at least one letter'
      : 'Le mot de passe doit contenir au moins une lettre';
  String get passwordNeedsDigit => _en
      ? 'Password must contain at least one digit'
      : 'Le mot de passe doit contenir au moins un chiffre';
  String get passwordNeedsSymbol => _en
      ? 'Password must contain at least one symbol'
      : 'Le mot de passe doit contenir au moins un symbole';
  String get passwordsNotMatch =>
      _en ? 'Passwords do not match' : 'Les mots de passe ne correspondent pas';
  String get confirmPasswordRequired => _en
      ? 'Please confirm your password'
      : 'Veuillez confirmer votre mot de passe';
  String get codeRequired => _en
      ? 'Please enter the 6-digit code'
      : 'Veuillez entrer un code à 6 chiffres';

  // Alerts
  String get createAccErrRetry => _en
      ? 'Unable to create account. Please try again.'
      : 'Impossible de créer le compte. Veuillez réessayer.';

  // Auth – Runtime error messages (returned by AuthNotifier methods)
  String get authNoUserLoggedIn =>
      _en ? 'No user logged in' : 'Aucun utilisateur connecté';
  String get authNoAccountForEmail => _en
      ? 'No account found for this email'
      : 'Aucun compte trouvé pour cet email';
  String get authCloudConnectionError => _en
      ? 'Unable to reach the server. Please check your connection and try again.'
      : 'Impossible de contacter le serveur. Vérifiez votre connexion et réessayez.';
  String authWrongProvider(String provider) => _en
      ? 'This account uses $provider. Sign in via that service.'
      : 'Ce compte utilise $provider. Connectez-vous via ce service.';
  String get authInvalidCredentials =>
      _en ? 'Incorrect email or password' : 'Email ou mot de passe incorrect';
  String authEmailNotVerified(String email) => _en
      ? 'Please verify your email. A code was sent to $email.'
      : 'Veuillez vérifier votre email. Un code a été envoyé à $email.';
  String get authInternetRequiredSignup => _en
      ? 'An internet connection is required to create an account'
      : 'Une connexion internet est requise pour créer un compte';
  String get authFirstLastNameRequired =>
      _en ? 'First and last name are required' : 'Prénom et nom sont obligatoires';
  String get authEmailAlreadyUsed => _en
      ? 'An account already exists for this email'
      : 'Un compte existe déjà pour cet email';
  String get authPhoneAlreadyUsed => _en
      ? 'An account already exists for this phone number'
      : 'Un compte existe déjà pour ce numéro de téléphone';
  String authGoogleFailed(String error) =>
      _en ? 'Google sign-in failed: $error' : 'Connexion Google échouée: $error';
  String get authAppleNoEmail =>
      _en ? 'Apple did not provide an email' : "Apple n'a pas fourni d'email";
  String authAppleFailed(String error) =>
      _en ? 'Apple sign-in failed: $error' : 'Connexion Apple échouée: $error';
  String authOAuthEmailConflict(String provider) => _en
      ? 'This email is already linked to a $provider account.'
      : 'Cet email est déjà associé à un compte $provider.';
  String get authInvalidPlan =>
      _en ? 'Invalid plan' : 'Forfait invalide';
  String get authInternetRequiredDelete => _en
      ? 'An internet connection is required to delete your account'
      : 'Une connexion internet est requise pour supprimer votre compte';
  String get authDeleteOrgBlocker => _en
      ? 'Delete or transfer the organization administration before deleting your account.'
      : "Supprimez ou transférez l'administration de l'organisation avant de supprimer votre compte.";
  String authDeleteError(String e) =>
      _en ? 'Error during deletion: $e' : 'Erreur lors de la suppression : $e';
  String authPasswordNotModifiable(String provider) => _en
      ? 'Password cannot be changed for $provider accounts'
      : 'Mot de passe non modifiable pour les comptes $provider';
  String get authCurrentPasswordIncorrect =>
      _en ? 'Incorrect current password' : 'Mot de passe actuel incorrect';
  String authEmailNotModifiable(String provider) => _en
      ? 'Email cannot be changed for $provider accounts'
      : 'Email non modifiable pour les comptes $provider';
  String get authEmailAlreadyInUse => _en
      ? 'This email is already in use by another account'
      : 'Cet email est déjà utilisé par un autre compte';
  String get authNoVerificationCodePending => _en
      ? 'No verification code pending. Please request a new one.'
      : 'Aucun code de vérification en attente. Veuillez en demander un nouveau.';
  String get authCodeExpired => _en
      ? 'The code has expired. Please request a new one.'
      : 'Le code a expiré. Veuillez en demander un nouveau.';
  String get authInvalidVerificationCode =>
      _en ? 'Invalid verification code' : 'Code de vérification invalide';
  String get authNoRecoveryCodePending => _en
      ? 'No recovery code pending. Please request a new one.'
      : 'Aucun code de récupération en attente. Veuillez en demander un nouveau.';
  String get authInvalidRecoveryCode =>
      _en ? 'Invalid recovery code' : 'Code de récupération invalide';
  String get authNoAccountForEmailRecovery =>
      _en ? 'No account associated with this email' : 'Aucun compte associé à cet email';
  String authOAuthNoRecovery(String provider) => _en
      ? 'This account uses $provider. Code recovery is not available for this account type.'
      : "Ce compte utilise $provider. La récupération par code n'est pas disponible pour ce type de compte.";

  // ─── Auth – Login ─────────────────────────────────────────────────────────
  String get welcomeBack => _en ? 'Welcome' : 'Bienvenue';
  String get loginSubtitle => _en
      ? 'Sign in to manage your leads'
      : 'Connectez-vous pour gérer vos leads';
  String get login => _en ? 'Sign in' : 'Se connecter';
  String get forgotPassword =>
      _en ? 'Forgot password?' : 'Mot de passe oublié ?';
  String get noAccount => _en ? 'No account?' : 'Pas de compte ?';
  String get signup => _en ? 'Create account' : 'Créer un compte';

  // ─── Auth – Signup ───────────────────────────────────────────────────────
  String get signupSubtitle => _en
      ? 'Join Me2Leads and start converting your contacts.'
      : 'Rejoignez Me2Leads et commencez\nà convertir vos contacts.';
  String get firstName => _en ? 'First name' : 'Prénom';
  String get firstNameHint => _en ? 'Jean' : 'Jean';
  String get firstNameRequired =>
      _en ? 'Please enter your first name' : 'Veuillez entrer votre prénom';
  String get lastName => _en ? 'Last name' : 'Nom';
  String get lastNameHint => _en ? 'Dupont' : 'Dupont';
  String get lastNameRequired =>
      _en ? 'Please enter your last name' : 'Veuillez entrer votre nom';
  String get phoneOptional =>
      _en ? 'Phone (optional)' : 'Téléphone (optionnel)';
  String get phoneHintAuth => '+237 6 99 88 77 66';
  String get confirmPasswordLabel =>
      _en ? 'Confirm password' : 'Confirmer le mot de passe';
  String get confirmPasswordHint =>
      _en ? 'Repeat your password' : 'Répétez le mot de passe';
  String get passwordHintAuth => _en
      ? '8-15 chars, letter + digit + symbol'
      : '8-15 caractères, lettre + chiffre + symbole';
  String get hasAccount =>
      _en ? 'Already have an account?' : 'Déjà un compte ?';

  // ─── Auth – Forgot Password ───────────────────────────────────────────────
  String get forgotPasswordTitle =>
      _en ? 'Forgot password' : 'Mot de passe oublié';
  String get forgotPasswordSubtitle => _en
      ? 'Enter the email linked to your account'
      : "Entrez l'email lié à votre compte";
  String get sendCode => _en ? 'Send code' : 'Envoyer le code';
  String get backToLogin => _en ? 'Back to login' : 'Retour à la connexion';

  // ─── Auth – Email Verification ────────────────────────────────────────────
  String get emailVerificationTitle =>
      _en ? 'Email Verification' : 'Vérification d\'email';
  String get emailVerificationSubtitle => _en
      ? 'Verify your email address to activate your account'
      : "Vérifiez votre adresse email pour activer votre compte";
  String get verificationCodeSent => _en
      ? 'A verification code has been sent to'
      : 'Un code de vérification a été envoyé à';
  String get resendCode => _en ? 'Resend code' : 'Renvoyer le code';
  String get resendCodeIn => _en ? 'Resend in' : 'Renvoyer dans';
  String get verify => _en ? 'Verify' : 'Vérifier';
  String get emailVerified =>
      _en ? 'Email successfully verified!' : 'Email vérifié avec succès !';
  String codeSentTo(String email) =>
      _en ? 'Code resent to $email' : 'Code renvoyé à $email';

  // ─── Auth – Recovery Code ─────────────────────────────────────────────────
  String get recoveryCodeTitle =>
      _en ? 'Verification Code' : 'Code de vérification';
  String get recoveryCodeSent => _en
      ? 'A recovery code has been sent to'
      : 'Un code de récupération a été envoyé à';

  // ─── Auth – Reset Password ────────────────────────────────────────────────
  String get newPasswordTitle => _en ? 'New password' : 'Nouveau mot de passe';
  String get newPasswordSubtitle => _en
      ? 'Create a new secure password'
      : 'Créez un nouveau mot de passe sécurisé';
  String get newPassword => _en ? 'New password' : 'Nouveau mot de passe';
  String get newPasswordHint => _en
      ? '8-15 chars, letter + digit + symbol'
      : '8-15 caractères, lettre + chiffre + symbole';
  String get confirmNewPassword =>
      _en ? 'Confirm new password' : 'Confirmer le nouveau mot de passe';
  String get passwordRules => _en
      ? '8-15 chars, 1 letter, 1 digit, 1 symbol, no spaces'
      : '8-15 car., 1 lettre, 1 chiffre, 1 symbole, sans espace';
  String get resetPassword => _en ? 'Reset' : 'Réinitialiser';
  String get passwordResetSuccess => _en
      ? 'Password successfully reset'
      : 'Mot de passe réinitialisé avec succès';

  // ─── Contacts ────────────────────────────────────────────────────────────
  String contactsCount(int n) =>
      _en ? '$n Contact${n != 1 ? 's' : ''}' : '$n Contact${n > 1 ? 's' : ''}';
  String get all => _en ? 'All' : 'Tous';
  String get noContactFound =>
      _en ? 'No contacts found' : 'Aucun contact trouvé';
  String get callLabel => _en ? 'Call' : 'Appeler';
  String get smsLabel => 'SMS';
  String get whatsappLabel => 'WhatsApp';
  String get emailActionLabel => 'Email';
  String get informationLabel => _en ? 'Information' : 'Informations';
  String get notesLabel => _en ? 'Notes' : 'Notes';
  String get historyLabel => _en ? 'History' : 'Historique';
  String get projects => _en ? 'Projects' : 'Projets';
  String get qrCode => 'QR Code';
  String get editButton => _en ? 'Edit' : 'Modifier';
  String get deleteButton => _en ? 'Delete' : 'Supprimer';
  String get shareButton => _en ? 'Share' : 'Partager';
  String get contactNotFound =>
      _en ? 'Contact not found' : 'Contact non trouvé';
  String get back => _en ? 'Back' : 'Retour';
  String get phoneLabel => _en ? 'Phone' : 'Téléphone';
  String get companyLabel => _en ? 'Company' : 'Société';
  String get sourceLabel => _en ? 'Source' : 'Source';
  String get project1Label => _en ? 'Project 1' : 'Projet 1';
  String get budgetLabel => _en ? 'Budget' : 'Budget';
  String get project2Label => _en ? 'Project 2' : 'Projet 2';
  String get deleteContactTitle =>
      _en ? 'Delete contact?' : 'Supprimer le contact ?';
  String deleteContactMessage(String name) => _en
      ? 'Are you sure you want to permanently delete $name? This action is irreversible.'
      : 'Êtes-vous sûr de vouloir supprimer définitivement $name ? Cette action est irréversible.';
  String get cancel => _en ? 'Cancel' : 'Annuler';
  String get delete => _en ? 'Delete' : 'Supprimer';
  String get reminderSection => _en ? 'Reminders' : 'Rappels';
  String get modificationBadge => _en ? 'EDIT' : 'MODIFICATION';
  String get completedReminderBadge => _en ? 'DONE REMINDER' : 'RAPPEL TERMINÉ';
  String get hotStatus => '● Hot Lead';
  String get warmStatus => '● Warm Lead';
  String get coldStatus => '● Cold Lead';
  String get fullHistory => _en ? 'Full History' : 'Historique complet';
  String get noHistory => _en ? 'No history' : 'Aucun historique';
  String get noPendingReminders =>
      _en ? 'No pending reminders' : 'Aucun rappel en attente';
  String get allPendingReminders =>
      _en ? 'Pending reminders' : 'Rappels en attente';

  // ─── Contact Edit ─────────────────────────────────────────────────────────
  String get addContact => _en ? 'Add manually' : 'Ajouter manuellement';
  String get editContact => _en ? 'Edit contact' : 'Modifier le contact';
  String get addContactSubtitle => _en
      ? 'Enter the contact information'
      : 'Renseignez les informations du contact';
  String get editContactSubtitle =>
      _en ? 'Update the information' : 'Mettez à jour les informations';
  String get jobTitleLabel => _en ? 'Position' : 'Fonction';
  String get tagsLabel => _en ? 'Tags' : 'Tags';
  String get saveButton => _en ? 'Save' : 'Enregistrer';
  String get statusLabel => _en ? 'Status' : 'Statut';
  String get project1Section => _en ? 'PROJECT 1' : 'PROJET 1';
  String get project2Section => _en ? 'PROJECT 2' : 'PROJET 2';
  String get projectNameLabel => _en ? 'Project name' : 'Nom du projet';
  String get emailPhoneRequired => _en
      ? '* At least one phone or email is required'
      : '* Au moins un téléphone ou un email est requis';
  String get lastNameRequired2 =>
      _en ? 'Last name is required' : 'Le nom de famille est obligatoire';
  String get contactCreated =>
      _en ? 'Contact created successfully' : 'Contact créé avec succès';
  String get contactUpdated => _en ? 'Contact updated' : 'Contact mis à jour';

  // ─── Review ──────────────────────────────────────────────────────────────
  String get reviewTitle => _en ? 'Review' : 'Vérification';
  String get reviewSubtitle => _en
      ? 'Verify and complete the information'
      : 'Vérifiez et complétez les informations';
  String get ocrConfidence =>
      _en ? 'OCR - 95% confidence' : 'OCR - 95% de confiance';
  String get quickActions => _en ? 'Quick actions' : 'Actions rapides';
  String get contactSaved =>
      _en ? 'Contact saved successfully!' : 'Contact sauvegardé avec succès !';
  String actionInProgress(String label) =>
      _en ? '$label in progress...' : '$label en cours...';
  String get project1Review => _en ? 'Project 1' : 'Projet 1';
  String get project1BudgetReview =>
      _en ? 'Project 1 Budget' : 'Budget Projet 1';
  String get project2Review => _en ? 'Project 2' : 'Projet 2';
  String get project2BudgetReview =>
      _en ? 'Project 2 Budget' : 'Budget Projet 2';

  // ─── Reminders ───────────────────────────────────────────────────────────
  String get remindersTitle => _en ? 'Reminders' : 'Rappels';
  String get remindersSubtitle =>
      _en ? 'Your tasks and follow-ups' : 'Vos tâches et suivis';
  String get tabToday => _en ? 'Today' : "Aujourd'hui";
  String get tabWeek => _en ? 'Week' : 'Semaine';
  String get tabLater => _en ? 'Later' : 'Plus tard';
  String get tabLate => _en ? 'Overdue' : 'En retard';
  String get tabDone => _en ? 'Done' : 'Terminés';
  String get newReminder => _en ? 'New reminder' : 'Nouveau rappel';
  String get noReminder => _en ? 'No reminders' : 'Aucun rappel';
  String get noReminderDesc =>
      _en ? 'Press + to create one.' : 'Appuyez sur + pour en créer un.';
  String get contactDeleted => _en ? 'Deleted contact' : 'Contact supprimé';
  String get addedToCalendar =>
      _en ? 'Added to calendar' : 'Ajouté au calendrier';

  // ─── Create Reminder ─────────────────────────────────────────────────────
  String get newReminderTitle => _en ? 'New reminder' : 'Nouveau rappel';
  String get editReminderTitle => _en ? 'Edit reminder' : 'Modifier le rappel';
  String get contactsSection => _en ? 'Contacts' : 'Contacts';
  String get planningSection => _en ? 'Schedule' : 'Planification';
  String get noteSection => _en ? 'Note' : 'Note';
  String get todoSection => _en ? 'To do' : 'À faire';
  String get prioritySection => _en ? 'Priority' : 'Priorité';
  String get selectContacts =>
      _en ? 'Select contacts' : 'Sélectionner des contacts';
  String get noContactsAvailable =>
      _en ? 'No contacts available' : 'Aucun contact disponible';
  String validateContacts(int n) => _en ? 'Confirm ($n)' : 'Valider ($n)';
  String get startLabel => _en ? 'Start' : 'Début';
  String get endLabel => _en ? 'End (optional)' : 'Fin (optionnel)';
  String get repeatLabel =>
      _en ? 'Repeat (optional)' : 'Répétition (optionnel)';
  String get noteHint =>
      _en ? 'Ex: Remind about 50k offer' : 'Ex: Rappeler pour offre 50k';
  String get repeatNone => _en ? 'None' : 'Aucune';
  String get repeat30min => _en ? 'Every 30 min' : 'Toutes les 30 min';
  String get repeatHourly => _en ? 'Every hour' : 'Toutes les heures';
  String get repeatDaily => _en ? 'Every day' : 'Chaque jour';
  String get repeatWeekly => _en ? 'Every week' : 'Chaque semaine';
  String get repeatMonthly => _en ? 'Every month' : 'Chaque mois';
  String get actionCall => _en ? 'Call' : 'Appeler';
  String get actionSms => 'SMS';
  String get actionWhatsapp => 'WhatsApp';
  String get actionEmail => 'Email';
  String get priorityNormal => _en ? 'Normal' : 'Normal';
  String get priorityImportant => _en ? 'Important' : 'Important';
  String get priorityVeryImportant => _en ? 'Very important' : 'Très important';
  String get createReminderBtn => _en ? 'Create reminder' : 'Créer le rappel';
  String get saveReminderBtn => _en ? 'Save' : 'Enregistrer';
  String get contactRequired =>
      _en ? 'At least 1 contact required' : 'Au moins 1 contact requis';
  String get noteRequired => _en ? 'Note required' : 'Note requise';
  String get addButton => _en ? '+ Add' : '+ Ajouter';

  // ─── Reminder Detail ──────────────────────────────────────────────────────
  String get reminderNotFound =>
      _en ? 'Reminder not found' : 'Rappel introuvable';
  String get affectedContacts =>
      _en ? 'Affected contacts' : 'Contacts concernés';
  String get actionSection => _en ? 'Action' : 'Action';
  String get statusSection => _en ? 'Status' : 'Statut';
  String get completedStatus => _en ? 'Done' : 'Terminé';
  String get addToCalendar => _en ? 'Add to calendar' : 'Ajouter au calendrier';
  String get deleteReminderTitle =>
      _en ? 'Delete reminder?' : 'Supprimer le rappel ?';
  String get deleteReminderWarning =>
      _en ? 'This action is irreversible.' : 'Cette action est irréversible.';
  String get sendSms => _en ? 'Send SMS' : 'Envoyer un SMS';
  String get openWhatsapp => _en ? 'Open WhatsApp' : 'Ouvrir WhatsApp';
  String get sendEmail => _en ? 'Send email' : 'Envoyer un email';

  // ─── Profile ─────────────────────────────────────────────────────────────
  String get accountLabel => _en ? 'Account' : 'Compte';
  String get myProfile => _en ? 'My Profile' : 'Mon Profil';
  String get myProfileDesc => _en
      ? 'View and edit my information'
      : 'Consulter et modifier mes informations';
  String get accountSecurity => _en ? 'Account Security' : 'Sécurité du compte';
  String get accountSecurityDesc =>
      _en ? 'Password and deletion' : 'Mot de passe et suppression';
  String get notificationsTitle => _en ? 'Notifications' : 'Notifications';
  String get notificationsDesc => _en ? 'Manage alerts' : 'Gérer les alertes';
  String get subscriptionLabel => _en ? 'Subscription' : 'Abonnement';
  String get subscriptionDesc =>
      _en ? 'Manage your plan' : 'Gérer votre forfait';
  String get syncLabel => _en ? 'Sync' : 'Synchronisation';
  String get syncDesc => _en ? 'Cloud & backup' : 'Cloud & sauvegarde';
  String get exportLabel => _en ? 'Import/Export' : 'Importer/Exporter';
  String get exportDesc => _en ? 'CSV, CRM, contacts' : 'CSV, CRM, contacts';
  String get settingsLabel => _en ? 'Settings' : 'Paramètres';
  String get settingsDesc => _en ? "App preferences" : "Préférences de l'app";
  String get logoutLabel => _en ? 'Logout' : 'Déconnexion';
  String get logoutDesc => _en ? 'Sign out' : 'Se déconnecter';
  String get photoTooLarge => _en
      ? 'Image too large. Maximum allowed size is 5 MB.'
      : "L'image est trop volumineuse. La taille maximale autorisée est de 5 Mo.";

  // ─── My Profile ───────────────────────────────────────────────────────────
  String get nicknameLabel => _en ? 'Nickname' : 'Surnom';
  String get companyNameLabel => _en ? 'Company' : 'Société';
  String get companyRoleLabel => _en ? 'Role' : 'Fonction';
  String get biographyLabel => _en ? 'Biography' : 'Biographie';
  String get editMode => _en ? 'Edit' : 'Modifier';
  String get viewMode => _en ? 'View' : 'Consulter';
  String get qrCodeSection => _en ? 'QR Code' : 'QR Code';
  String get qrCodeHint =>
      _en ? 'Scan to view profile' : 'Scannez pour voir le profil';
  String get saveChanges =>
      _en ? 'Save changes' : 'Enregistrer les modifications';
  String get profileUpdated => _en ? 'Profile updated' : 'Profil mis à jour';
  String get editHint =>
      _en ? 'Edit your information' : 'Modifiez vos informations';
  String get firstNameRequired2 =>
      _en ? 'First name required' : 'Prénom requis';
  String get lastNameRequired3 => _en ? 'Last name required' : 'Nom requis';
  String get biographyHint =>
      _en ? 'A few words about you...' : 'Quelques mots sur vous...';

  // ─── Account Security ─────────────────────────────────────────────────────
  String get accountSecuritySubtitle => _en
      ? 'Manage your account security'
      : 'Gérez la sécurité de votre compte';
  String get changePassword =>
      _en ? 'Change password' : 'Changer le mot de passe';
  String get currentPassword =>
      _en ? 'Current password' : 'Mot de passe actuel';
  String get newPasswordLabel => _en ? 'New password' : 'Nouveau mot de passe';
  String get confirmPasswordSec =>
      _en ? 'Confirm new password' : 'Confirmer le nouveau mot de passe';
  String get passwordChanged => _en
      ? 'Password successfully changed'
      : 'Mot de passe modifié avec succès';
  String get changeEmail => _en ? "Change email" : "Changer l'email";
  String get newEmail => _en ? 'New email' : 'Nouvel email';
  String get sendVerificationCode => _en ? 'Send code' : 'Envoyer le code';
  String get verificationCodeLabel =>
      _en ? 'Verification code' : 'Code de vérification';
  String get emailChangedSuccess =>
      _en ? 'Email successfully changed' : 'Email modifié avec succès';
  String get deleteAccountTitle =>
      _en ? 'Delete account' : 'Supprimer le compte';
  String get deleteAccountWarning => _en
      ? 'This action is irreversible. All your data will be deleted.'
      : 'Cette action est irréversible. Toutes vos données seront supprimées.';
  String get deleteMyAccount =>
      _en ? 'Delete my account' : 'Supprimer mon compte';
  String get deleteAccountConfirmTitle =>
      _en ? 'Delete my account' : 'Supprimer mon compte';
  String get deleteAccountConfirmMessage => _en
      ? 'This action is permanent. All your contacts, reminders, interactions and payment methods will be deleted. Do you really want to continue?'
      : 'Cette action est définitive. Tous vos contacts, rappels, interactions et moyens de paiement seront supprimés. Voulez-vous vraiment continuer ?';
  String get currentPasswordRequired =>
      _en ? 'Current password required' : 'Mot de passe actuel requis';
  String get newPasswordRequired =>
      _en ? 'New password required' : 'Nouveau mot de passe requis';
  String get passwordInvalidFormat => _en
      ? 'Invalid format (see rules below)'
      : 'Format invalide (voir règles ci-dessous)';
  String get confirmRequired =>
      _en ? 'Confirmation required' : 'Confirmation requise';
  String get changeEmailLabel =>
      _en ? "Change email address" : "Changer l'adresse email";

  // ─── Settings Screen ──────────────────────────────────────────────────────
  String get settingsTitle => _en ? 'Settings' : 'Paramètres';
  String get appearance => _en ? 'Appearance' : 'Apparence';
  String get themeColor => _en ? 'Theme Color' : 'Couleur du thème';
  String get themeColorDesc => _en
      ? 'Switch between light and dark mode'
      : 'Basculer entre mode clair et sombre';
  String get lightMode => _en ? 'Light' : 'Clair';
  String get darkMode => _en ? 'Dark' : 'Sombre';
  String get languageOption => _en ? 'Language' : 'Langue';
  String get languageDesc =>
      _en ? 'Change display language' : "Changer la langue d'affichage";
  String get languageFr => _en ? 'French' : 'Français';
  String get languageEn => _en ? 'English' : 'Anglais';
  String get currencyOption => _en ? 'Currency' : 'Devise';
  String get currencyDesc => _en
      ? 'Set your preferred currency for subscriptions and transactions'
      : 'Définir votre devise préférée pour les abonnements et transactions';
  String get currencyEur => _en ? 'Euro (€)' : 'Euro (€)';
  String get currencyUsd => _en ? 'US Dollar (\$)' : 'Dollar américain (\$)';
  String get settingsApplied =>
      _en ? 'Settings applied' : 'Paramètres appliqués';

  // ─── Subscription Hub ─────────────────────────────────────────────────────
  String get subscriptionHubTitle => _en ? 'Subscription' : 'Abonnement';
  String get subscriptionHubSubtitle => _en
      ? 'Manage your plan and billing'
      : 'Gérez votre forfait et facturation';
  String get currentPlanBadge => _en ? 'CURRENT PLAN' : 'PLAN ACTUEL';
  String get freePlanName => _en ? 'Free' : 'Gratuit';
  String get freePlanTagline =>
      _en ? 'Discover Me2Leads' : 'Découvrir Me2Leads';
  String get upgradeNow => _en ? 'Upgrade now' : 'Améliorer maintenant';
  String get managePlan => _en ? 'Manage plan' : 'Gérer le forfait';
  String get subscriptionPlanOption =>
      _en ? 'Subscription Plan' : "Plan d'abonnement";
  String get subscriptionPlanOptionDesc =>
      _en ? 'View and change your plan' : 'Voir et changer votre plan';
  String get paymentHistoryOption =>
      _en ? 'Payment History' : 'Historique des paiements';
  String get paymentHistoryOptionDesc =>
      _en ? 'View past transactions' : 'Voir les transactions passées';
  String get secureTransactions => _en
      ? 'Secure transactions • Cancel anytime'
      : 'Transactions sécurisées • Annulation à tout moment';

  // ─── Subscription Plan Screen ─────────────────────────────────────────────
  String get choosePlan =>
      _en ? 'Choose your plan' : 'Choisissez votre forfait';
  String get popularBadge => _en ? 'POPULAR' : 'POPULAIRE';
  String get currentBadge => _en ? 'CURRENT' : 'ACTUEL';
  String get freePlanDesc =>
      _en ? 'To discover Me2Leads' : 'Pour découvrir Me2Leads';
  String get premiumPlanName => 'Premium';
  String get premiumPlanDesc =>
      _en ? 'For demanding professionals' : 'Pour les professionnels exigeants';
  String get businessPlanName => 'Business';
  String get businessPlanDesc =>
      _en ? 'For sales teams' : 'Pour les équipes commerciales';
  String get choosePlanCta => _en ? 'Choose' : 'Choisir';
  String get paymentMethodsTitle =>
      _en ? 'PAYMENT METHODS' : 'MOYENS DE PAIEMENT';
  String get securePayment => _en
      ? 'Secure payment. Cancel anytime.'
      : 'Paiement sécurisé. Annulation à tout moment.';
  String get comingSoon => _en ? ' plan coming soon!' : ' bientôt disponible !';
  String get freeLabel => _en ? 'Free' : 'Gratuit';
  String get planChangedSuccess =>
      _en ? 'Plan updated successfully' : 'Forfait mis à jour avec succès';
  String get planChangeError =>
      _en ? 'Error changing plan' : 'Erreur lors du changement de forfait';
  String get bankCard => _en ? 'Bank card' : 'Carte bancaire';

  // ─── Payment History ─────────────────────────────────────────────────────
  String get paymentHistoryTitle =>
      _en ? 'Payment History' : 'Historique des paiements';
  String get filterByDate => _en ? 'Filter by date' : 'Filtrer par date';
  String get allTime => _en ? 'All time' : 'Tout';
  String get thisMonth => _en ? 'This month' : 'Ce mois';
  String get last3Months => _en ? 'Last 3 months' : '3 derniers mois';
  String get last6Months => _en ? 'Last 6 months' : '6 derniers mois';
  String get thisYear => _en ? 'This year' : 'Cette année';
  String get noPayments =>
      _en ? 'No payments yet' : 'Aucun paiement pour le moment';
  String get noPaymentsDesc => _en
      ? 'Your payment history will appear here once you subscribe to a plan.'
      : 'Votre historique de paiements apparaîtra ici une fois que vous vous abonnerez à un plan.';
  String get transactionId => _en ? 'Transaction ID' : 'ID Transaction';
  String get plan => _en ? 'Plan' : 'Plan';
  String get amount => _en ? 'Amount' : 'Montant';
  String get date => _en ? 'Date' : 'Date';
  String get statusPaid => _en ? 'Paid' : 'Payé';
  String get statusFailed => _en ? 'Failed' : 'Échoué';
  String get statusPending => _en ? 'Pending' : 'En attente';

  // ─── Scan ─────────────────────────────────────────────────────────────────
  String get scanTitle => _en ? 'Scanner' : 'Scanner';
  String get scanHint => _en
      ? 'Place the business card in the frame'
      : 'Placez la carte de visite dans le cadre';
  String get scanCard => _en ? 'Card' : 'Carte';
  String get scanQR => _en ? 'QR Code' : 'QR Code';
  String get scanNFC => _en ? 'NFC' : 'NFC';
  String get cardDetected => _en ? 'Card detected!' : 'Carte détectée !';
  String get cameraUnavailable =>
      _en ? 'Camera unavailable' : 'Caméra non disponible';

  // ─── Notifications ────────────────────────────────────────────────────────
  String get notificationsScreenTitle =>
      _en ? 'Notifications' : 'Notifications';
  String get noNotifications =>
      _en ? 'No notifications' : 'Aucune notification';
  String get noNotificationsDesc => _en
      ? 'Your alerts and reminders will appear here.'
      : 'Vos alertes et rappels apparaîtront ici.';
  String get markAllRead => _en ? 'Mark all read' : 'Tout lire';
  String get searchNotifications =>
      _en ? 'Search a notification…' : 'Rechercher une notification…';
  String noResultsFor(String q) =>
      _en ? 'No results for "$q"' : 'Aucun résultat pour "$q"';
  String get overdueReminderBadge =>
      _en ? 'OVERDUE REMINDER' : 'RAPPEL EN RETARD';
  String get upcomingReminderBadge =>
      _en ? 'UPCOMING REMINDER' : 'RAPPEL À VENIR';
  String get incompleteProfileBadge =>
      _en ? 'INCOMPLETE PROFILE' : 'PROFIL INCOMPLET';
  String get notificationLabel => _en ? 'NOTIFICATION' : 'NOTIFICATION';

  // ─── Organization ─────────────────────────────────────────────────────────
  String get orgSectionTitle => _en ? 'Organization' : 'Organisation';
  String get createOrgTitle =>
      _en ? 'Create an organization' : "Créer une organisation";
  String get createOrgDesc => _en
      ? 'Group your team under a single account and manage members.'
      : "Regroupez votre équipe sous un seul compte et gérez les membres.";
  String get joinOrgTitle =>
      _en ? 'Join an organization' : 'Rejoindre une organisation';
  String get joinOrgDesc => _en
      ? 'Enter the invite code provided by your administrator.'
      : "Entrez le code d'invitation fourni par votre administrateur.";
  String get orgName => _en ? 'ORGANIZATION NAME' : 'NOM DE L\'ORGANISATION';
  String get orgNameHint => _en ? 'e.g. Acme Corp' : 'ex. Société Dupont';
  String get orgNameRequired =>
      _en ? 'Name is required' : 'Le nom est obligatoire';
  String get orgCreated => _en
      ? 'Organization created successfully'
      : 'Organisation créée avec succès';
  String get orgAdminMenuTitle => _en ? 'My Organization' : 'Mon organisation';
  String get orgAdminMenuDesc =>
      _en ? 'Manage members and settings' : 'Gérer les membres et paramètres';
  String get orgMemberMenuDesc =>
      _en ? 'View your organization' : 'Voir votre organisation';
  String get createOrJoinOrg => _en
      ? 'Create or join an organization'
      : "Créer ou rejoindre une organisation";
  String get inviteCode => _en ? 'INVITE CODE' : "CODE D'INVITATION";
  String get inviteCodeHint =>
      _en ? 'Enter 8-character code' : 'Code à 8 caractères';
  String get inviteCodeLabel =>
      _en ? 'Your invite code' : "Votre code d'invitation";
  String get copyCode => _en ? 'Copy code' : 'Copier le code';
  String get codeCopied => _en ? 'Code copied!' : 'Code copié !';
  String get joinOrg => _en ? 'Join' : 'Rejoindre';
  String get orgJoined =>
      _en ? 'You joined the organization' : "Vous avez rejoint l'organisation";
  String get orgMembersTitle => _en ? 'Members' : 'Membres';
  String get orgAdminBadge => _en ? 'Admin' : 'Admin';
  String get orgMemberBadge => _en ? 'Member' : 'Membre';
  String get memberSince => _en ? 'Since' : 'Depuis';
  String get removeMember => _en ? 'Remove' : 'Retirer';
  String get removeMemberTitle => _en ? 'Remove member' : 'Retirer le membre';
  String removeMemberConfirm(String name) => _en
      ? 'Remove $name from the organization?'
      : 'Retirer $name de l\'organisation ?';
  String get leaveOrg => _en ? 'Leave organization' : "Quitter l'organisation";
  String get leaveOrgTitle =>
      _en ? 'Leave organization' : "Quitter l'organisation";
  String get leaveOrgConfirm => _en
      ? 'Are you sure you want to leave this organization?'
      : 'Êtes-vous sûr de vouloir quitter cette organisation ?';
  String get deleteOrg =>
      _en ? 'Delete organization' : "Supprimer l'organisation";
  String get deleteOrgTitle =>
      _en ? 'Delete organization' : "Supprimer l'organisation";
  String get deleteOrgConfirm => _en
      ? 'This will permanently remove the organization and all memberships. Continue?'
      : "Cela supprimera définitivement l'organisation et tous les membres. Continuer ?";
  String get orgSettingsTitle =>
      _en ? 'Organization settings' : "Paramètres de l'organisation";
  String get shareInviteCode =>
      _en ? 'Share invite code' : "Partager le code d'invitation";
  String get inviteInfo => _en
      ? 'Share this code so colleagues can join your organization.'
      : 'Partagez ce code pour que vos collègues rejoignent votre organisation.';
  String get noOrgMembers =>
      _en ? 'No members yet' : 'Aucun membre pour le moment';
  String orgContactsCount(int n) =>
      _en ? '$n contact${n == 1 ? '' : 's'}' : '$n contact${n > 1 ? 's' : ''}';
  String get orgDeletedSuccess =>
      _en ? 'Organization deleted' : 'Organisation supprimée';
  String get memberRemovedSuccess => _en ? 'Member removed' : 'Membre retiré';
  String get orgLeftSuccess => _en
      ? 'You have left the organization'
      : "Vous avez quitté l'organisation";
  String get orgNameUpdated =>
      _en ? 'Organization name updated' : "Nom de l'organisation mis à jour";
  String get noEditPermission => _en
      ? 'You do not have permission to edit this contact'
      : "Vous n'avez pas la permission de modifier ce contact";
  String get noCreatePermission => _en
      ? 'You do not have permission to create contacts'
      : "Vous n'avez pas la permission de créer des contacts";
  String get editPrivilege =>
      _en ? 'Can edit contacts' : 'Peut modifier les contacts';
  String get createPrivilege =>
      _en ? 'Can create contacts' : 'Peut créer des contacts';
  String get privilegeUpdated =>
      _en ? 'Privileges updated' : 'Privilèges mis à jour';
  String get privileges => _en ? 'Privileges' : 'Privilèges';
  String get viewRemindersPrivilege =>
      _en ? 'Can view shared reminders' : 'Peut voir les rappels partagés';
  String get viewHistoryPrivilege => _en
      ? 'Can view shared contact history'
      : "Peut voir l'historique des contacts partagés";
  String get memberManagement => _en ? 'Manage member' : 'Gérer le membre';
  String get youLabel => _en ? '(you)' : '(vous)';
  String get suspendMember => _en ? 'Suspend' : 'Suspendre';
  String get suspendMemberTitle =>
      _en ? 'Suspend member' : 'Suspendre le membre';
  String suspendMemberConfirm(String name) => _en
      ? 'Suspend $name? They will lose access to the organisation.'
      : 'Suspendre $name ? Il/elle perdra l\'accès à l\'organisation.';
  String get reactivateMember => _en ? 'Reactivate' : 'Réactiver';
  String get reactivateMemberTitle =>
      _en ? 'Reactivate member' : 'Réactiver le membre';
  String reactivateMemberConfirm(String name) => _en
      ? 'Reactivate $name and restore their access?'
      : 'Réactiver $name et rétablir son accès ?';
  String get memberSuspendedSuccess =>
      _en ? 'Member suspended' : 'Membre suspendu';
  String get memberReactivatedSuccess =>
      _en ? 'Member reactivated' : 'Membre réactivé';
  String get suspendedBadge => _en ? 'SUSPENDED' : 'SUSPENDU';
  String get regenerateCode => _en ? 'Regenerate code' : 'Régénérer le code';
  String get regenerateCodeTitle =>
      _en ? 'Regenerate invite code' : "Régénérer le code d'invitation";
  String get regenerateCodeConfirm => _en
      ? 'The current code will be invalidated immediately. Members who have not yet joined will need the new code.'
      : 'Le code actuel sera invalidé immédiatement. Les membres qui n\'ont pas encore rejoint auront besoin du nouveau code.';
  String get codeRegenerated =>
      _en ? 'Invite code regenerated' : "Code d'invitation régénéré";
  String get orgStatsTitle => _en ? 'Organisation' : 'Organisation';
  String orgTotalContacts(int n) => _en
      ? '$n total contact${n == 1 ? '' : 's'}'
      : '$n contact${n > 1 ? 's' : ''} au total';
  String orgActiveMembers(int n) => _en
      ? '$n active member${n == 1 ? '' : 's'}'
      : '$n membre${n > 1 ? 's' : ''} actif${n > 1 ? 's' : ''}';

  // ─── Import / Export ─────────────────────────────────────────────────────
  String get importExportTitle => _en ? 'Import / Export' : 'Import / Export';
  String get importExportSubtitle =>
      _en ? 'Manage your contacts' : 'Gérez vos contacts';
  String get importTab => _en ? 'Import' : 'Importer';
  String get exportTab => _en ? 'Export' : 'Exporter';

  String get importSection => _en ? 'Import contacts' : 'Importer des contacts';
  String get importSectionDesc => _en
      ? 'Load contacts from a file'
      : 'Charger des contacts depuis un fichier';
  String get exportSection => _en ? 'Export contacts' : 'Exporter les contacts';
  String exportSectionDesc(int n) => _en
      ? 'Export your $n contact${n == 1 ? '' : 's'}'
      : 'Exporter vos $n contact${n > 1 ? 's' : ''}';

  String get csvImportDesc => _en
      ? 'Salesforce, Odoo, SAP or generic'
      : 'Salesforce, Odoo, SAP ou générique';
  String get vcardImportDesc =>
      _en ? 'Standard vCard / contacts app' : 'vCard standard / app Contacts';
  String get txtImportDesc =>
      _en ? 'Me2Leads TXT format' : 'Format TXT Me2Leads';

  String get vcardExportDesc => _en
      ? 'Universal contacts format (RFC 6350)'
      : 'Format contacts universel (RFC 6350)';
  String get txtExportDesc =>
      _en ? 'Readable plain text' : 'Texte brut lisible';
  String csvExportDesc(String formatName) =>
      _en ? '$formatName compatible CSV' : 'CSV compatible $formatName';

  String get crmFormatLabel => _en ? 'CRM format' : 'Format CRM';
  String get exportFormatLabel => _en ? 'File format' : 'Format de fichier';
  String get crmFormatGeneric => _en ? 'Generic' : 'Générique';

  String get importInfoBox => _en
      ? 'Supported: CSV (Salesforce, Odoo, SAP, generic), vCard (.vcf), and Me2Leads TXT. Contacts with neither phone nor email will be skipped.'
      : 'Formats supportés : CSV (Salesforce, Odoo, SAP, générique), vCard (.vcf) et TXT Me2Leads. Les contacts sans téléphone ni email sont ignorés.';
  String get exportInfoBox => _en
      ? 'Choose a CRM format for CSV to ensure compatibility. vCard and TXT are universal.'
      : "Choisissez un format CRM pour le CSV afin d'assurer la compatibilité. vCard et TXT sont universels.";

  String importSuccess(int created, int skipped) {
    final base = _en
        ? '$created contact${created == 1 ? '' : 's'} imported'
        : '$created contact${created > 1 ? 's' : ''} importé${created > 1 ? 's' : ''}';
    if (skipped == 0) return base;
    final skip = _en
        ? ', $skipped duplicate${skipped == 1 ? '' : 's'} skipped'
        : ', $skipped doublon${skipped > 1 ? 's' : ''} ignoré${skipped > 1 ? 's' : ''}';
    return '$base$skip';
  }

  String get importError => _en
      ? 'Error reading file. Please check the format.'
      : 'Erreur lors de la lecture. Vérifiez le format du fichier.';
  String get importNoContacts => _en
      ? 'No valid contacts found in the file.'
      : 'Aucun contact valide trouvé dans le fichier.';
  String exportSuccess(int n) => _en
      ? 'Export ready — $n contact${n == 1 ? '' : 's'}'
      : 'Export prêt — $n contact${n > 1 ? 's' : ''}';
  String get exportError => _en ? 'Export failed' : "Échec de l'export";
  String get exportNoContacts =>
      _en ? 'No contacts to export' : 'Aucun contact à exporter';

  String get importPreviewTitle =>
      _en ? 'Import preview' : "Aperçu de l'importation";
  String importPreviewDesc(int n) => _en
      ? '$n contact${n == 1 ? '' : 's'} found'
      : '$n contact${n > 1 ? 's' : ''} trouvé${n > 1 ? 's' : ''}';
  String importPreviewMore(int n) => _en ? '+ $n more...' : '+ $n autres...';
  String get confirmImport => _en ? 'Import' : 'Importer';

  // TXT format guide
  String get txtGuideTitle => _en ? 'TXT Format Guide' : 'Guide du format TXT';
  String get txtGuideSubtitle => _en
      ? 'Recommended structure for best import results'
      : 'Structure recommandée pour de meilleurs résultats';
  String get txtGuideShowBtn =>
      _en ? 'View format guide' : 'Voir le guide de format';
  String get txtGuideHideBtn => _en ? 'Hide guide' : 'Masquer le guide';
  String get txtGuideTemplateLabel => _en ? 'Template' : 'Modèle';
  String get txtGuideFieldsLabel =>
      _en ? 'Fields reference' : 'Référence des champs';
  String get txtGuideRequired => _en ? 'Required' : 'Obligatoire';
  String get txtGuideOptional => _en ? 'Optional' : 'Optionnel';
  String get txtGuideSeparatorNote => _en
      ? 'Each contact must start with a separator line: --- Contact N ---'
      : 'Chaque contact doit commencer par une ligne de séparation : --- Contact N ---';
  String get txtGuidePhoneEmailNote => _en
      ? 'At least Phone or Email is required. Contacts missing both will be skipped.'
      : 'Au moins Téléphone ou Email est obligatoire. Les contacts sans les deux seront ignorés.';
  String get txtGuideStatusNote => _en
      ? 'Status values: "Hot Lead", "Warm Lead" (default), or "Cold Lead".'
      : 'Valeurs de Statut : "Hot Lead", "Warm Lead" (défaut), ou "Cold Lead".';
  String get txtGuideTagsNote => _en
      ? 'Tags are comma-separated, e.g. "VIP, Partner, Tech".'
      : 'Les tags sont séparés par des virgules, ex. : "VIP, Partenaire, Tech".';
  String get txtGuideMultiNote => _en
      ? 'Multiple contacts in one file are supported. Increment the number in each separator.'
      : 'Un fichier peut contenir plusieurs contacts. Incrémentez le numéro dans chaque séparateur.';

  // CSV format guide
  String get csvGuideTitle => _en ? 'CSV Format Guide' : 'Guide du format CSV';
  String get csvGuideSubtitle => _en
      ? 'Supported headers for Salesforce, Odoo, SAP and generic CSV'
      : 'En-têtes supportés pour Salesforce, Odoo, SAP et CSV générique';
  String get csvGuideShowBtn =>
      _en ? 'View format guide' : 'Voir le guide de format';
  String get csvGuideHideBtn => _en ? 'Hide guide' : 'Masquer le guide';
  String get csvGuideTemplateLabel =>
      _en ? 'Generic template' : 'Modèle générique';
  String get csvGuideColumnsLabel =>
      _en ? 'Accepted column names' : 'Noms de colonnes acceptés';
  String get csvGuideHeaderNote => _en
      ? 'The first row must be a header row. Column names are case-insensitive.'
      : 'La première ligne doit être une ligne d\'en-tête. Les noms de colonnes ne sont pas sensibles à la casse.';
  String get csvGuideAutoDetectNote => _en
      ? 'The CRM format (Salesforce, Odoo, SAP) is auto-detected from the column headers — no manual selection needed.'
      : 'Le format CRM (Salesforce, Odoo, SAP) est détecté automatiquement depuis les en-têtes — aucune sélection manuelle nécessaire.';
  String get csvGuidePhoneEmailNote => _en
      ? 'At least Phone or Email is required per row. Rows missing both are skipped.'
      : 'Au moins Téléphone ou Email est requis par ligne. Les lignes sans les deux sont ignorées.';
  String get csvGuideFullNameNote => _en
      ? 'Odoo\'s "name" column (full name) is split automatically into first and last name.'
      : 'La colonne "name" d\'Odoo (nom complet) est découpée automatiquement en prénom et nom.';
  String get csvGuideStatusNote => _en
      ? 'Status: Salesforce uses Hot/Warm/Cold (Rating), SAP uses HIGH/MEDIUM/LOW (PRIORITY).'
      : 'Statut : Salesforce utilise Hot/Warm/Cold (Rating), SAP utilise HIGH/MEDIUM/LOW (PRIORITY).';
  String get csvGuideTsvNote => _en
      ? 'TSV (tab-separated) files with a .csv or .tsv extension are also supported.'
      : 'Les fichiers TSV (séparés par des tabulations) avec extension .csv ou .tsv sont aussi acceptés.';

  // vCard format guide
  String get vcardGuideTitle =>
      _en ? 'vCard Format Guide' : 'Guide du format vCard';
  String get vcardGuideSubtitle => _en
      ? 'Supports vCard 2.1, 3.0 and 4.0 (.vcf)'
      : 'Compatible vCard 2.1, 3.0 et 4.0 (.vcf)';
  String get vcardGuideShowBtn =>
      _en ? 'View format guide' : 'Voir le guide de format';
  String get vcardGuideHideBtn => _en ? 'Hide guide' : 'Masquer le guide';
  String get vcardGuideTemplateLabel => _en ? 'Template' : 'Modèle';
  String get vcardGuidePropsLabel =>
      _en ? 'Supported properties' : 'Propriétés supportées';
  String get vcardGuideNameNote => _en
      ? 'At least FN: (full name) or N: (structured name) is required.'
      : 'Au moins FN: (nom complet) ou N: (nom structuré) est requis.';
  String get vcardGuidePhoneEmailNote => _en
      ? 'At least TEL: or EMAIL: is required. Only the first of each type is imported.'
      : 'Au moins TEL: ou EMAIL: est requis. Seule la première occurrence de chaque type est importée.';
  String get vcardGuideStatusNote => _en
      ? 'X-ME2LEADS-STATUS: accepts hot, warm, or cold. Defaults to warm if absent.'
      : 'X-ME2LEADS-STATUS: accepte hot, warm ou cold. La valeur par défaut est warm si absente.';
  String get vcardGuideFoldingNote => _en
      ? 'Long-line folding (RFC 6350 — lines continued with a leading space or tab) is handled automatically.'
      : 'Le repli de lignes longues (RFC 6350 — lignes continuées par un espace ou tabulation) est géré automatiquement.';
  String get vcardGuideMultiNote => _en
      ? 'Multiple contacts per file are supported — each block delimited by BEGIN:VCARD / END:VCARD.'
      : 'Un fichier peut contenir plusieurs contacts — chaque bloc délimité par BEGIN:VCARD / END:VCARD.';

  // ─── Remote Sync ─────────────────────────────────────────────────────────
  String get syncScreenTitle => _en ? 'Cloud Sync' : 'Sync Cloud';
  String get syncLastSyncLabel => _en ? 'Last sync' : 'Dernière sync';
  String get syncNever => _en ? 'Never' : 'Jamais';
  String get syncUploadTitle =>
      _en ? 'Upload to cloud' : 'Envoyer vers le cloud';
  String get syncUploadDesc => _en
      ? 'Back up your local data to the remote database'
      : 'Sauvegarder vos données locales sur le serveur distant';
  String get syncDownloadTitle =>
      _en ? 'Download from cloud' : 'Télécharger du cloud';
  String get syncDownloadDesc => _en
      ? 'Restore your data from the remote database'
      : 'Restaurer vos données depuis le serveur distant';
  String get syncInProgress =>
      _en ? 'Sync in progress…' : 'Synchronisation en cours…';
  String get syncSuccess => _en ? 'Sync completed' : 'Synchronisation terminée';
  String get syncConfirmPullTitle =>
      _en ? 'Overwrite local data?' : 'Écraser les données locales ?';
  String get syncConfirmPullBody => _en
      ? 'Your local contacts and reminders will be replaced with the cloud version. This cannot be undone.'
      : 'Vos contacts et rappels locaux seront remplacés par la version du cloud. Cette action est irréversible.';
  String get syncErrNoConnection =>
      _en ? 'No internet connection' : 'Pas de connexion internet';
  String get syncErrAuthFailed => _en
      ? 'Could not connect to the database'
      : 'Impossible de se connecter à la base de données';
  String get syncErrUnknown => _en
      ? 'An unexpected error occurred'
      : 'Une erreur inattendue est survenue';
  String syncResultLabel(int contacts, int reminders) => _en
      ? '$contacts contact${contacts == 1 ? '' : 's'}, $reminders reminder${reminders == 1 ? '' : 's'} synced'
      : '$contacts contact${contacts == 1 ? '' : 's'}, $reminders rappel${reminders == 1 ? '' : 's'} synchronisé${reminders == 1 ? '' : 's'}';
  String get syncLockedDesc => _en
      ? 'Premium & Business plans only'
      : 'Forfaits Premium et Business uniquement';
  String get syncPlanGateTitle => _en
      ? 'Upgrade to sync your data'
      : 'Passez à un forfait supérieur pour synchroniser';
  String get syncPlanGateBody => _en
      ? 'Cloud sync is available on Premium and Business plans. Back up your contacts and access them across all your devices.'
      : 'La synchronisation cloud est disponible sur les forfaits Premium et Business. Sauvegardez vos contacts et accédez-y sur tous vos appareils.';

  // ─── Currency helpers ─────────────────────────────────────────────────────
  // [eurToTargetRate] is the live EUR → target-currency rate (e.g. 1.08 for USD).
  // Callers that watch [eurToUsdRateProvider] should pass the live value;
  // the default (1.08) is a reasonable fallback for EUR → USD.
  String premiumPrice(AppCurrency c, {double eurToTargetRate = 1.08}) =>
      c == AppCurrency.usd
          ? '\$${(2.99 * eurToTargetRate).toStringAsFixed(2)}'
          : '2.99€';
  String premiumPeriod(AppCurrency c) =>
      c == AppCurrency.usd ? '/month' : '/ mois';
  String businessPrice(AppCurrency c, {double eurToTargetRate = 1.08}) =>
      c == AppCurrency.usd
          ? '\$${(5.99 * eurToTargetRate).toStringAsFixed(2)}'
          : '5.99€';
  String businessPeriod(AppCurrency c) =>
      c == AppCurrency.usd ? '/user/month' : '/ utilisateur / mois';
  String currencySymbol(AppCurrency c) => c == AppCurrency.usd ? '\$' : '€';
}

final l10nProvider = Provider<AppL10n>((ref) {
  final lang = ref.watch(settingsProvider).language;
  return AppL10n(lang == AppLanguage.en);
});
