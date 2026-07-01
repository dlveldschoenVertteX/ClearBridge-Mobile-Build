import 'package:cloud_firestore/cloud_firestore.dart';

class ApplicationData {
  final String? id;
  final String userId;
  final String firstName;
  final String surname;
  final String phone;
  final String? email;
  final String idNumber;
  final DateTime createdAt;
  final DateTime? dob; // Auto-calculated from ID
  final String? streetAddress;
  final String? suburb;
  final String? city;
  final String? province;
  final String? postalCode;
  final String? currentLocation;

  final String? selfieUrl;
  final String? idFrontUrl;
  final String? idBackUrl;
  final String? fingerprintUrl;

  // Payment and Status Fields
  final String? tier;
  final double? price;
  final String? paymentReference;
  final String status;
  final DateTime? deadlineAt;
  final String? certificateUrl;
  final Map<String, bool>? notificationSettings;

  /// ClearCoin balance (0–60). Managed exclusively by Cloud Functions via
  /// Firestore transactions — intentionally NOT serialized in [toMap] so that
  /// routine profile writes (which use set/merge with toMap) can never clobber
  /// the tracked balance. Capture sessions can earn up to 50; referral bonus
  /// adds a further 10 when the referred user purchases a clearance.
  final int clearCoinBalance;

  /// True once the +10 referral ClearCoin bonus has been awarded.
  /// Set server-side; read-only on the client. Excluded from [toMap].
  final bool referralCoinsClaimed;

  ApplicationData({
    this.id,
    required this.userId,
    required this.firstName,
    required this.surname,
    required this.phone,
    this.email,
    required this.idNumber,
    required this.createdAt,
    this.dob,
    this.streetAddress,
    this.suburb,
    this.city,
    this.province,
    this.postalCode,
    this.currentLocation,
    this.selfieUrl,
    this.idFrontUrl,
    this.idBackUrl,
    this.fingerprintUrl,
    this.tier,
    this.price,
    this.paymentReference,
    this.status = 'submitted',
    this.deadlineAt,
    this.certificateUrl,
    this.notificationSettings,
    this.clearCoinBalance = 0,
    this.referralCoinsClaimed = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'firstName': firstName,
      'surname': surname,
      'phone': phone,
      'email': email,
      'idNumber': idNumber,
      'createdAt': Timestamp.fromDate(createdAt),
      'dob': dob != null ? Timestamp.fromDate(dob!) : null,
      'streetAddress': streetAddress,
      'suburb': suburb,
      'city': city,
      'province': province,
      'postalCode': postalCode,
      'currentLocation': currentLocation,
      'selfieUrl': selfieUrl,
      'idFrontUrl': idFrontUrl,
      'idBackUrl': idBackUrl,
      'fingerprintUrl': fingerprintUrl,
      'tier': tier,
      'price': price,
      'paymentReference': paymentReference,
      'status': status,
      'deadlineAt': deadlineAt != null ? Timestamp.fromDate(deadlineAt!) : null,
      'certificateUrl': certificateUrl,
      'notificationSettings': notificationSettings,
    };
  }

  ApplicationData copyWith({
    String? id,
    String? userId,
    String? firstName,
    String? surname,
    String? phone,
    String? email,
    String? idNumber,
    DateTime? createdAt,
    DateTime? dob,
    String? streetAddress,
    String? suburb,
    String? city,
    String? province,
    String? postalCode,
    String? currentLocation,
    String? selfieUrl,
    String? idFrontUrl,
    String? idBackUrl,
    String? fingerprintUrl,
    String? tier,
    double? price,
    String? paymentReference,
    String? status,
    DateTime? deadlineAt,
    String? certificateUrl,
    Map<String, bool>? notificationSettings,
    int? clearCoinBalance,
    bool? referralCoinsClaimed,
  }) {
    return ApplicationData(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      firstName: firstName ?? this.firstName,
      surname: surname ?? this.surname,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      idNumber: idNumber ?? this.idNumber,
      createdAt: createdAt ?? this.createdAt,
      dob: dob ?? this.dob,
      streetAddress: streetAddress ?? this.streetAddress,
      suburb: suburb ?? this.suburb,
      city: city ?? this.city,
      province: province ?? this.province,
      postalCode: postalCode ?? this.postalCode,
      currentLocation: currentLocation ?? this.currentLocation,
      selfieUrl: selfieUrl ?? this.selfieUrl,
      idFrontUrl: idFrontUrl ?? this.idFrontUrl,
      idBackUrl: idBackUrl ?? this.idBackUrl,
      fingerprintUrl: fingerprintUrl ?? this.fingerprintUrl,
      tier: tier ?? this.tier,
      price: price ?? this.price,
      paymentReference: paymentReference ?? this.paymentReference,
      status: status ?? this.status,
      deadlineAt: deadlineAt ?? this.deadlineAt,
      certificateUrl: certificateUrl ?? this.certificateUrl,
      notificationSettings: notificationSettings ?? this.notificationSettings,
      clearCoinBalance: clearCoinBalance ?? this.clearCoinBalance,
      referralCoinsClaimed: referralCoinsClaimed ?? this.referralCoinsClaimed,
    );
  }

  factory ApplicationData.fromMap(Map<String, dynamic> map, String documentId) {
    return ApplicationData(
      id: documentId,
      userId: map['userId'] ?? '',
      firstName: map['firstName'] ?? '',
      surname: map['surname'] ?? '',
      phone: map['phone'] ?? '',
      email: map['email'],
      idNumber: map['idNumber'] ?? '',
      createdAt: map['createdAt'] != null
          ? (map['createdAt'] as Timestamp).toDate().toUtc()
          : DateTime.now().toUtc(),
      dob: (map['dob'] as Timestamp?)?.toDate().toUtc(),
      streetAddress: map['streetAddress'],
      suburb: map['suburb'],
      city: map['city'],
      province: map['province'],
      postalCode: map['postalCode'],
      currentLocation: map['currentLocation'],
      selfieUrl: map['selfieUrl'],
      idFrontUrl: map['idFrontUrl'],
      idBackUrl: map['idBackUrl'],
      fingerprintUrl: map['fingerprintUrl'],
      tier: map['tier'],
      price: (map['price'] as num?)?.toDouble(),
      paymentReference: map['paymentReference'],
      status: map['status'] ?? 'submitted',
      deadlineAt: (map['deadlineAt'] as Timestamp?)?.toDate().toUtc(),
      certificateUrl: map['certificateUrl'],
      notificationSettings: map['notificationSettings'] != null
          ? Map<String, bool>.from(map['notificationSettings'])
          : null,
      clearCoinBalance: (map['clearCoinBalance'] as num?)?.toInt() ?? 0,
      referralCoinsClaimed: (map['referralCoinsClaimed'] as bool?) ?? false,
    );
  }
}
