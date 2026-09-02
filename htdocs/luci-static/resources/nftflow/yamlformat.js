'use strict';
'require baseclass';

var INDENT = '  ';

function leadingWidth(line) {
    var width = 0;

    for (var i = 0; i < line.length; i++) {
        if (line.charAt(i) === ' ')
            width++;
        else if (line.charAt(i) === '\t')
            width += 2;
        else
            break;
    }

    return width;
}

function formatYaml(source) {
    var text = String(source || '').replace(/\r\n?/g, '\n');
    var rawLines = text.split('\n');
    var levels = [ 0 ];
    var output = [];
    var previousWidth = 0;
    var previousLevel = 0;
    var previousOpensBlock = false;
    var blockScalarWidth = null;

    for (var i = 0; i < rawLines.length; i++) {
        var raw = rawLines[i].replace(/[ \t]+$/, '');
        var trimmed = raw.replace(/^[ \t]+/, '');

        if (!trimmed) {
            if (output.length && output[output.length - 1] !== '')
                output.push('');
            continue;
        }

        var width = leadingWidth(raw);

        if (blockScalarWidth !== null) {
            if (width > blockScalarWidth) {
                output.push(raw.replace(/^\t+/, function(tabs) { return INDENT.repeat(tabs.length); }));
                continue;
            }
            blockScalarWidth = null;
        }

        while (levels.length > 1 && width < levels[levels.length - 1])
            levels.pop();

        var level;
        if (i > 0 && width > previousWidth && previousOpensBlock) {
            if (levels[levels.length - 1] !== width)
                levels.push(width);
            level = previousLevel + 1;
        } else {
            var knownIndex = levels.indexOf(width);
            if (knownIndex >= 0)
                level = knownIndex;
            else if (width > levels[levels.length - 1]) {
                levels.push(width);
                level = levels.length - 1;
            } else {
                level = levels.length - 1;
            }
        }

        output.push(INDENT.repeat(level) + trimmed);

        previousWidth = width;
        previousLevel = level;
        previousOpensBlock = /:\s*(?:#.*)?$/.test(trimmed) || /^-\s*(?:#.*)?$/.test(trimmed);

        if (/[:>-]\s*[|>]\s*[+-]?\d*\s*(?:#.*)?$/.test(trimmed) || /:\s*[|>]\s*[+-]?\d*\s*(?:#.*)?$/.test(trimmed))
            blockScalarWidth = width;
    }

    while (output.length && output[output.length - 1] === '')
        output.pop();

    return output.join('\n') + (output.length ? '\n' : '');
}

return baseclass.extend({
    format: formatYaml
});
