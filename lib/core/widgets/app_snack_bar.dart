import 'package:flutter/material.dart';
import 'package:mangabaka_app/core/constants/app_constants.dart';
import 'package:mangabaka_app/core/theme/app_typography.dart';
import 'package:mangabaka_app/desktop/desktop_layout.dart';

/// Centralized SnackBar and Toast presenter.
///
/// On desktop platforms, displays messages as compact floating toasts in the
/// bottom-right corner of the window. On mobile platforms, displays them as
/// floating snackbars.
class AppSnackBar {
  AppSnackBar._();

  /// Displays a message toast or snackbar.
  static void show(
    BuildContext context,
    String message, {
    SnackBarAction? action,
    bool isError = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();

    final isDesktop = DesktopLayout.isDesktopPlatform;

    if (isDesktop) {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.only(right: 28, bottom: 28, left: 28),
          duration: duration,
          content: Align(
            alignment: Alignment.bottomRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppConstants.secondaryBackground,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppConstants.borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 18,
                    color: isError
                        ? AppConstants.errorColor
                        : AppConstants.accentColor,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      message,
                      style: AppTypography.sans(
                        color: AppConstants.textColor,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ).copyWith(decoration: TextDecoration.none),
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: action.onPressed,
                      style: TextButton.styleFrom(
                        foregroundColor:
                            action.textColor ?? AppConstants.accentColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        action.label,
                        style: AppTypography.sans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppConstants.secondaryBackground,
          duration: duration,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.denseRadius),
            side: BorderSide(color: AppConstants.borderColor),
          ),
          content: Row(
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 18,
                color: isError
                    ? AppConstants.errorColor
                    : AppConstants.accentColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.sans(
                    color: AppConstants.textColor,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ],
          ),
          action: action,
        ),
      );
    }
  }
}
