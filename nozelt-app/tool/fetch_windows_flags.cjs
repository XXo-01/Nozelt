// Offline Twemoji flag assets; pinned upstream revision and attribution.
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
async function get(url) {
  const response = await fetch(url, {headers: {'User-Agent': 'Nozelt-assets'}});
  if (!response.ok) throw Error(`Asset request failed: ${response.status}`);
  return response;
}
async function main() {
  const tree = await (await get('https://api.github.com/repos/jdecked/twemoji/git/trees/v17.0.3?recursive=1')).json();
  if (tree.truncated) throw Error('Incomplete upstream asset tree');
  const flags = tree.tree.filter(x => /^assets\/72x72\/1f1[0-9a-f]{2}-1f1[0-9a-f]{2}\.png$/.test(x.path));
  if (flags.length < 250) throw Error('Flag inventory incomplete');
  const output = path.join(root, 'assets', 'flags');
  fs.mkdirSync(output, {recursive:true});
  const countries = [];
  let cursor = 0;
  await Promise.all(Array.from({length:6}, async () => {
    while(cursor < flags.length) {
      const entry = flags[cursor++];
      const codes = path.basename(entry.path, '.png').split('-').map(x => parseInt(x,16));
      const country = String.fromCharCode(...codes.map(x => x - 0x1f1e6 + 65));
      const bytes = Buffer.from(await (await get(`https://raw.githubusercontent.com/jdecked/twemoji/${tree.sha}/${entry.path}`)).arrayBuffer());
      fs.writeFileSync(path.join(output, country + '.png'), bytes);
      countries.push(country);
    }
  }));
  fs.writeFileSync(path.join(root,'lib/src/ui/widgets/flag_countries.dart'),
    `// Twemoji v17.0.3, revision ${tree.sha}.\nconst flagCountries = <String>{\n${countries.sort().map(c => `  '${c}',`).join('\n')}\n};\n`);
  const licenses = path.join(root,'assets/licenses');
  fs.mkdirSync(licenses,{recursive:true});
  const license = await (await get(`https://raw.githubusercontent.com/jdecked/twemoji/${tree.sha}/LICENSE-GRAPHICS`)).text();
  fs.writeFileSync(path.join(licenses,'Twemoji.txt'),`Twemoji flag graphics by Twitter, Inc. and other contributors.\nhttps://github.com/jdecked/twemoji\nv17.0.3 (${tree.sha}); unmodified 72x72 PNG flag graphics.\n\n${license}`);
  console.log(`${countries.length} local flags saved (${tree.sha}).`);
}
main().catch(e => {console.error(e.message);process.exitCode=1;});
