import 'package:country_code_picker/country_code_picker.dart';
import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

class PhonePrefixInput extends StatefulWidget {
  final TextEditingController controller;
  final String? hint;
  final String? Function(String?)? validator;
  final bool showLabel;
  final String? labelText;
  final TextInputAction? textInputAction;

  const PhonePrefixInput({
    super.key,
    required this.controller,
    this.hint,
    this.validator,
    this.showLabel = false,
    this.labelText,
    this.textInputAction,
  });

  @override
  State<PhonePrefixInput> createState() => _PhonePrefixInputState();
}

class _PhonePrefixInputState extends State<PhonePrefixInput> {
  String _selectedPrefix = '+352';
  late final TextEditingController _numberCtrl;
  bool _isUpdatingFromInternal = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.controller.text.trim();
    final parsed = _parseFullNumber(initial);
    
    _selectedPrefix = parsed.prefix;
    _numberCtrl = TextEditingController(text: parsed.number);
    
    _numberCtrl.addListener(_onInternalChanged);
    widget.controller.addListener(_onExternalChanged);
  }

  ({String prefix, String number}) _parseFullNumber(String full) {
    String clean = full.trim();
    if (clean.startsWith('00')) {
      clean = '+' + clean.substring(2);
    }

    if (!clean.startsWith('+')) {
      return (prefix: '+352', number: clean);
    }

    // Try to find the longest matching dial code.
    // Dial codes can be 1 to 4 digits (e.g., +1, +33, +352, +1242)
    for (int i = 5; i >= 2; i--) {
      if (clean.length >= i) {
        final potential = clean.substring(0, i);
        if (RegExp(r'^\+\d+$').hasMatch(potential)) {
          // Here we could ideally validate against a real list of dial codes.
          // For now, we assume it's a valid prefix if it matches the pattern.
          return (prefix: potential, number: clean.substring(i).trim());
        }
      }
    }
    
    return (prefix: '+352', number: clean);
  }

  void _onInternalChanged() {
    if (_isUpdatingFromInternal) return;
    _isUpdatingFromInternal = true;
    final num = _numberCtrl.text.trim();
    if (num.isEmpty) {
      widget.controller.text = '';
    } else {
      // Avoid double prefix if it's already there (though internal logic should prevent it)
      widget.controller.text = '$_selectedPrefix $num';
    }
    _isUpdatingFromInternal = false;
  }

  void _onExternalChanged() {
    if (_isUpdatingFromInternal) return;
    final externalValue = widget.controller.text.trim();
    
    if (externalValue.isEmpty) {
      if (_numberCtrl.text.isNotEmpty) {
        _isUpdatingFromInternal = true;
        _numberCtrl.text = '';
        _isUpdatingFromInternal = false;
      }
      return;
    }

    final parsed = _parseFullNumber(externalValue);

    if (parsed.prefix != _selectedPrefix) {
      setState(() {
        _selectedPrefix = parsed.prefix;
      });
    }
    
    if (parsed.number != _numberCtrl.text) {
      _isUpdatingFromInternal = true;
      _numberCtrl.text = parsed.number;
      _isUpdatingFromInternal = false;
    }
  }

  @override
  void dispose() {
    _numberCtrl.removeListener(_onInternalChanged);
    widget.controller.removeListener(_onExternalChanged);
    _numberCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showLabel && widget.labelText != null) ...[
          Text(
            widget.labelText!.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.surfaceColor(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderColor(context), width: 2),
              ),
              child: CountryCodePicker(
                key: ValueKey(_selectedPrefix),
                onChanged: (code) {
                  if (code.dialCode != null) {
                    setState(() => _selectedPrefix = code.dialCode!);
                    _onInternalChanged();
                  }
                },
                initialSelection: _selectedPrefix,
                favorite: const ['+352', '+33', '+237', '+1'],
                showCountryOnly: false,
                showOnlyCountryWhenClosed: false,
                alignLeft: false,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                textStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context),
                ),
                dialogTextStyle: TextStyle(
                  fontSize: 14,
                  color: AppColors.onSurface(context),
                ),
                searchStyle: TextStyle(
                  fontSize: 14,
                  color: AppColors.onSurface(context),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _numberCtrl,
                keyboardType: TextInputType.phone,
                textInputAction: widget.textInputAction,
                validator: widget.validator,
                style: TextStyle(
                  fontSize: 14, 
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface(context)
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.surfaceColor(context),
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                    color: AppColors.hint(context).withOpacity(0.6),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.borderColor(context), width: 2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.borderColor(context), width: 2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.accent, width: 2),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.hot, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
