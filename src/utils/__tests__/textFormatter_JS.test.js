import { describe, it, expect } from 'vitest';
import { formatText } from '../textFormatter.js';

describe('textFormatter JS protection', () => {
    it('should NOT inject <br> tags into <script> blocks', () => {
        const input = 'Check this:\n<script>\nconsole.log("hello");\nconsole.log("world");\n</script>\nDone.';
        const output = formatText(input);

        // Should contain the script block preserved (mostly, might have some spacing around it due to block isolation)
        expect(output).toContain('<script>\nconsole.log("hello");\nconsole.log("world");\n</script>');
        // Should NOT contain <br> inside the script content
        const scriptMatch = output.match(/<script([\s\S]*?)<\/script>/);
        expect(scriptMatch[1]).not.toContain('<br>');
    });

    it('should isolate <script> blocks from paragraph wrapping', () => {
        const input = 'Paragraph 1\n\n<script>alert(1)</script>\n\nParagraph 2';
        const output = formatText(input);

        expect(output).toContain('<p>Paragraph 1</p>');
        expect(output).toContain('<script>alert(1)</script>');
        expect(output).toContain('<p>Paragraph 2</p>');
        // Script should NOT be inside <p>
        // Ensure `<script>` doesn't appear before the corresponding `</p>`
        expect(output).not.toMatch(/<p>(?:(?!<\/p>).)*<script/);
    });

    it('should handle unclosed script blocks during streaming by rendering as code', () => {
        const input = 'Wait for it...\n<script>\nconsole.log("streaming..."';
        const output = formatText(input);

        expect(output).toContain('<pre class="code-block" data-lang="javascript">');
        expect(output).toContain('console.log("streaming..."');
    });
});
