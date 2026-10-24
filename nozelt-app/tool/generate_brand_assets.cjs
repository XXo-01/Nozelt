const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const appRoot = path.resolve(__dirname, '..');
const sourceRoot = path.resolve(appRoot, '..', '..', 'Nozelt-assets');
const resRoot = path.join(appRoot, 'android', 'app', 'src', 'main', 'res');
const flutterRoot = path.join(appRoot, 'assets', 'branding');

const fullLogo = fs.readFileSync(
  path.join(sourceRoot, 'nozelt_new_logo.svg'),
);
const masterLogo = fs.readFileSync(
  path.join(sourceRoot, 'nozelt_new_master_logo.svg'),
  'utf8',
);
const whiteLogo = masterLogo.replace(
  /(<svg\b[^>]*>)/,
  '$1<style>#Shield path{fill:none!important;stroke:#fff!important}' +
    '#UpperLineAndRing path,#LowerLineAndRing path{fill:#fff!important}</style>',
);

const densities = [
  ['mdpi', 1],
  ['hdpi', 1.5],
  ['xhdpi', 2],
  ['xxhdpi', 3],
  ['xxxhdpi', 4],
];

async function render(source, size, output, background = null) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  let image = sharp(Buffer.from(source)).resize(size, size).png();
  if (background !== null) image = image.flatten({ background });
  await image.toFile(output);
}

async function renderAdaptive(source, size, output, logoScale = 0.66) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  // Adaptive launchers crop the 108dp foreground down to a roughly 66dp
  // safe zone. Keep the complete logo, including both terminal rings,
  // comfortably inside every launcher mask.
  const innerSize = Math.round(size * logoScale);
  const logo = await sharp(Buffer.from(source))
    .resize(innerSize, innerSize)
    .png()
    .toBuffer();
  await sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: logo, gravity: 'centre' }])
    .png()
    .toFile(output);
}

async function renderInset(source, size, output, logoScale, background) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const logo = await sharp(Buffer.from(source))
    .resize(Math.round(size * logoScale))
    .png()
    .toBuffer();
  await sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background,
    },
  })
    .composite([{ input: logo, gravity: 'centre' }])
    .png()
    .toFile(output);
}

async function renderTrimmed(source, canvasSize, artworkSize, output) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const artwork = await sharp(Buffer.from(source))
    .trim()
    .resize(artworkSize, artworkSize, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer();
  await sharp({
    create: {
      width: canvasSize,
      height: canvasSize,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: artwork, gravity: 'centre' }])
    .png()
    .toFile(output);
}

async function main() {
  await render(
    fullLogo,
    512,
    path.join(flutterRoot, 'nozelt_new_logo.png'),
    '#000000',
  );
  await render(
    whiteLogo,
    256,
    path.join(flutterRoot, 'nozelt_new_master_logo.png'),
  );

  for (const [density, scale] of densities) {
    await render(
      fullLogo,
      Math.round(48 * scale),
      path.join(resRoot, `mipmap-${density}`, 'ic_nozelt_launcher.png'),
      '#000000',
    );
    await renderInset(
      fullLogo,
      Math.round(48 * scale),
      path.join(resRoot, `mipmap-${density}`, 'ic_nozelt_launcher_round.png'),
      0.94,
      '#000000',
    );
    await renderAdaptive(
      fullLogo,
      Math.round(108 * scale),
      path.join(resRoot, `drawable-${density}`, 'ic_nozelt_adaptive_foreground.png'),
    );
    await renderAdaptive(
      fullLogo,
      Math.round(108 * scale),
      path.join(resRoot, `drawable-${density}`, 'ic_nozelt_adaptive_foreground_round.png'),
      0.62,
    );
    await renderAdaptive(
      masterLogo,
      Math.round(108 * scale),
      path.join(resRoot, `drawable-${density}`, 'ic_nozelt_adaptive_monochrome.png'),
    );
    await renderAdaptive(
      masterLogo,
      Math.round(108 * scale),
      path.join(resRoot, `drawable-${density}`, 'ic_nozelt_adaptive_monochrome_round.png'),
      0.62,
    );
    await renderTrimmed(
      fullLogo,
      Math.round(24 * scale),
      Math.round(22 * scale),
      path.join(
        resRoot,
        `drawable-${density}`,
        'ic_nozelt_notification_logo.png',
      ),
    );
    await renderTrimmed(
      masterLogo,
      Math.round(28.75 * scale),
      Math.round(26 * scale),
      path.join(resRoot, `drawable-${density}`, 'ic_nozelt_tile.png'),
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
