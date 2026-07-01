import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../services/certificate_service.dart';

class PDFViewerScreen extends ConsumerStatefulWidget {
  final String certificateUrl;
  final String reference;

  const PDFViewerScreen({
    super.key,
    required this.certificateUrl,
    required this.reference,
  });

  @override
  ConsumerState<PDFViewerScreen> createState() => _PDFViewerScreenState();
}

class _PDFViewerScreenState extends ConsumerState<PDFViewerScreen> {
  File? _localFile;
  bool _isLoading = true;
  String? _error;
  int _totalPages = 0;
  int _currentPage = 0;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _preparePdf();
  }

  Future<void> _preparePdf() async {
    try {
      final service = ref.read(certificateServiceProvider);
      final fileName = 'cert_${widget.reference}.pdf';

      // Check if already downloaded
      final existing = await service.getLocalCertificate(fileName);
      if (existing != null) {
        if (mounted) {
          setState(() {
            _localFile = existing;
            _isLoading = false;
          });
        }
        return;
      }

      // Download if not exists
      if (widget.certificateUrl.isEmpty) {
        throw Exception('Certificate URL is missing');
      }

      final file = await service.downloadCertificate(
        widget.certificateUrl,
        fileName,
      );
      if (mounted) {
        setState(() {
          _localFile = file;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load certificate. Please try again.';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleShare() async {
    if (_localFile == null) return;
    try {
      await ref
          .read(certificateServiceProvider)
          .shareCertificate(
            _localFile!.path,
            subject: 'Police Clearance Certificate - ${widget.reference}',
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to share certificate')),
      );
    }
  }

  Future<void> _handleDownload() async {
    if (_localFile == null) return;
    try {
      setState(() => _isDownloading = true);
      // On mobile, "Download" often means saving to a public folder
      // or opening with system viewer which allows "Save to Files"
      await ref
          .read(certificateServiceProvider)
          .openCertificate(_localFile!.path);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Certificate saved to Downloads')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to download certificate')),
      );
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: const Color(0x0AFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x14FFFFFF)),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: ClearBridgeColors.silverBright,
                        size: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Certificate Viewer',
                      style: ClearBridgeTypography.h2,
                    ),
                  ),
                  if (_localFile != null) ...[
                    IconButton(
                      icon: const Icon(Icons.share_rounded,
                          color: ClearBridgeColors.cyan),
                      onPressed: _handleShare,
                      tooltip: 'Share Certificate',
                    ),
                    IconButton(
                      icon: _isDownloading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: ClearBridgeColors.cyan,
                              ),
                            )
                          : const Icon(
                              Icons.download_for_offline_rounded,
                              color: ClearBridgeColors.cyan,
                            ),
                      onPressed: _handleDownload,
                      tooltip: 'Download / Open Externally',
                    ),
                  ],
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: ClearBridgeColors.cyan),
            const SizedBox(height: 16),
            Text(
              'Syncing secure document…',
              style: ClearBridgeTypography.body,
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: ClearBridgeColors.error,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: ClearBridgeTypography.body,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClearBridgeColors.cyan,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  _preparePdf();
                },
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: PDFView(
                filePath: _localFile!.path,
                enableSwipe: true,
                swipeHorizontal: false,
                autoSpacing: false,
                pageFling: true,
                onRender: (pages) {
                  setState(() => _totalPages = pages ?? 0);
                },
                onViewCreated: (PDFViewController controller) {},
                onPageChanged: (page, total) {
                  setState(() => _currentPage = page ?? 0);
                },
                onError: (error) {
                  setState(() => _error = error.toString());
                },
              ),
            ),
          ),
        ),
        if (_totalPages > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Text(
              'Page ${_currentPage + 1} of $_totalPages',
              style: const TextStyle(
                color: Colors.white60,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }
}
