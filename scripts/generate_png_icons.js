import sharp from 'sharp';
import path from 'path';
import fs from 'fs';

const inputPng = 'ComfyUI_temp_kelho_00001_.png';

const androidMipmaps = [
  { name: 'mipmap-mdpi', size: 108 },
  { name: 'mipmap-hdpi', size: 162 },
  { name: 'mipmap-xhdpi', size: 216 },
  { name: 'mipmap-xxhdpi', size: 324 },
  { name: 'mipmap-xxxhdpi', size: 432 }
];

async function generate() {
    try {
        // iOS
        await sharp(inputPng)
            .resize(1024, 1024, { fit: 'cover' })
            .toFile('ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png');
            
        // Android
        for (const mipmap of androidMipmaps) {
            const dir = `android/app/src/main/res/${mipmap.name}`;
            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }
            
            // Adaptive icon foreground
            await sharp(inputPng)
                .resize(mipmap.size, mipmap.size, { fit: 'cover' })
                .toFile(path.join(dir, 'ic_launcher_foreground.png'));
                
            // Legacy icons (older Android versions)
            const legacySize = Math.round(mipmap.size * (48/108));
            await sharp(inputPng)
                .resize(legacySize, legacySize, { fit: 'cover' })
                .toFile(path.join(dir, 'ic_launcher.png'));
            await sharp(inputPng)
                .resize(legacySize, legacySize, { fit: 'cover' })
                .toFile(path.join(dir, 'ic_launcher_round.png'));
        }
        console.log('Successfully generated PNG icons for iOS and Android.');
    } catch (e) {
        console.error('Error generating icons:', e);
    }
}
generate();