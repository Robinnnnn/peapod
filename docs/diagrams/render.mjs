import {readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {render} from 'pele';

const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

const themes = {
  light: {bg: '#ffffff', fg: '#19271e', muted: '#58665e', line: '#64776b',
    surface: '#f1f7f0', 'surface-alt': '#f8faf7', border: '#bdd0bf', accent: '#316b45'},
  dark: {bg: '#0d1117', fg: '#e3ede5', muted: '#a3b3a8', line: '#a1b9a8',
    surface: '#192a22', 'surface-alt': '#111c17', border: '#476353', accent: '#90cba1'},
};
for (const name of ['message-flow']) {
  const source = await readFile(new URL(`${name}.mmd`, import.meta.url), 'utf8');
  const title = source.match(/%% accTitle: (.+)/)?.[1];
  const description = source.match(/%% accDescr: (.+)/)?.[1];
  if (!title || !description) throw new Error('Diagram requires accessibility title and description comments.');
  for (const [theme, colors] of Object.entries(themes)) {
    const {svg, width, height} = render(source, {
      idPrefix: `${name}-${theme}`, fontFamily: 'Arial, Helvetica, sans-serif',
      fontSize: 16, padding: 24, maxWidth: 1000, autoDirection: false,
    });
    const variables = Object.entries(colors).map(([key, value]) => `--pele-${key}:${value}`).join(';');
    // Block diagrams do not parse accTitle/accDescr yet. Add the source comments as SVG metadata.
    const titleId = `${name}-${theme}-title`, descId = `${name}-${theme}-desc`;
    const accessible = svg.replace(/ aria-(?:labelledby|describedby)="[^"]*"/g, '')
      .replace('<svg ', `<svg aria-labelledby="${titleId}" aria-describedby="${descId}" `)
      .replace('>', `><title id="${titleId}">${escape(title)}</title><desc id="${descId}">${escape(description)}</desc>`);
    const themed = accessible.replace('style="', `style="${variables};background:${colors.bg};`);
    const target = new URL(`${name}-${theme}.svg`, import.meta.url);
    await writeFile(target, `${themed}\n`);
    console.log(`${fileURLToPath(target)} (${Math.round(width)} × ${Math.round(height)})`);
  }
}
