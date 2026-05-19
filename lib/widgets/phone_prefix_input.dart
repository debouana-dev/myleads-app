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
  final List<String> _prefixes = ['+352', '+1'];
  late final TextEditingController _numberCtrl;
  bool _isUpdatingFromInternal = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.controller.text.trim();
    String number = initial;
    
    for (var p in _prefixes) {
      if (initial.startsWith(p)) {
        _selectedPrefix = p;
        number = initial.substring(p.length).trim();
        break;
      }
    }
    
    _numberCtrl = TextEditingController(text: number);
    
    _numberCtrl.addListener(_onInternalChanged);
    widget.controller.addListener(_onExternalChanged);
  }

  void _onInternalChanged() {
    if (_isUpdatingFromInternal) return;
    _isUpdatingFromInternal = true;
    final num = _numberCtrl.text.trim();
    if (num.isEmpty) {
      widget.controller.text = '';
    } else {
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

    String number = externalValue;
    String? matchedPrefix;

    for (var p in _prefixes) {
      if (externalValue.startsWith(p)) {
        matchedPrefix = p;
        number = externalValue.substring(p.length).trim();
        break;
      }
    }

    if (matchedPrefix != null && matchedPrefix != _selectedPrefix) {
      setState(() {
        _selectedPrefix = matchedPrefix!;
      });
    }
    
    if (number != _numberCtrl.text) {
      _isUpdatingFromInternal = true;
      _numberCtrl.text = number;
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
              width: 90,
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceColor(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderColor(context), width: 2),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedPrefix,
                  isExpanded: true,
                  dropdownColor: AppColors.surfaceColor(context),
                  icon: Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.hint(context), size: 18),
                  items: _prefixes.map((p) => DropdownMenuItem(
                    value: p,
                    child: Text(p, style: TextStyle(
                      fontSize: 14, 
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface(context),
                    )),
                  )).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedPrefix = val);
                      _onInternalChanged();
                    }
                  },
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
