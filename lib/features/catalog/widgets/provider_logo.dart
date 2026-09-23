import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../catalog_models.dart';
import '../third_party_providers_provider.dart';

/// Bundled brand mark for each third-party source, kept in the service's own
/// colours (raster where the source only publishes one, vector where it does).
const Map<ThirdPartyProvider, String> _providerLogoAssets = {
  ThirdPartyProvider.janitor: 'assets/logos/providers/janitor.png',
  ThirdPartyProvider.janny: 'assets/logos/providers/janny.png',
  ThirdPartyProvider.datacat: 'assets/logos/providers/datacat.png',
  ThirdPartyProvider.chub: 'assets/logos/providers/chub.png',
  ThirdPartyProvider.saucepan: 'assets/logos/providers/saucepan.svg',
};

/// The source's real logo glyph, so it can stand in wherever the app used a
/// placeholder material icon.
class ProviderLogo extends StatelessWidget {
  final ThirdPartyProvider provider;
  final double size;

  const ProviderLogo({super.key, required this.provider, this.size = 18});

  ProviderLogo.catalog({
    super.key,
    required CatalogProvider provider,
    this.size = 18,
  }) : provider = provider.thirdPartyProvider;

  @override
  Widget build(BuildContext context) {
    final asset = _providerLogoAssets[provider];
    if (asset == null) {
      return SizedBox(width: size, height: size);
    }
    if (asset.endsWith('.svg')) {
      return SvgPicture.asset(asset, width: size, height: size);
    }
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
