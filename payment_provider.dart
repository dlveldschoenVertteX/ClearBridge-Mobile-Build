import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../services/payment_service.dart';

part 'payment_provider.g.dart';

@riverpod
class SelectedTier extends _$SelectedTier {
  @override
  String build() => 'priority';

  void setTier(String tier) => state = tier;
}

@riverpod
PaymentService paymentService(Ref ref) {
  return PaymentService();
}

enum PaymentStatus {
  idle,
  processing,
  verifying,
  success,
  failed,
  cancelled,
  error,
}

class PaymentState {
  final PaymentStatus status;
  final String? transactionRef;
  final String? errorMessage;

  PaymentState({required this.status, this.transactionRef, this.errorMessage});

  factory PaymentState.idle() => PaymentState(status: PaymentStatus.idle);
  factory PaymentState.processing() =>
      PaymentState(status: PaymentStatus.processing);
  factory PaymentState.verifying(String ref) =>
      PaymentState(status: PaymentStatus.verifying, transactionRef: ref);
  factory PaymentState.success(String ref) =>
      PaymentState(status: PaymentStatus.success, transactionRef: ref);
  factory PaymentState.failed(String ref, [String? msg]) => PaymentState(
    status: PaymentStatus.failed,
    transactionRef: ref,
    errorMessage: msg,
  );
  factory PaymentState.cancelled() =>
      PaymentState(status: PaymentStatus.cancelled);
  factory PaymentState.error(String msg) =>
      PaymentState(status: PaymentStatus.error, errorMessage: msg);
}

@riverpod
class PaymentNotifier extends _$PaymentNotifier {
  @override
  PaymentState build() => PaymentState.idle();

  void setIdle() => state = PaymentState.idle();
  void setProcessing() => state = PaymentState.processing();
  void setVerifying(String ref) => state = PaymentState.verifying(ref);
  void setSuccess(String ref) => state = PaymentState.success(ref);
  void setFailed(String ref, [String? msg]) =>
      state = PaymentState.failed(ref, msg);
  void setCancelled() => state = PaymentState.cancelled();
  void setError(String msg) => state = PaymentState.error(msg);
}
