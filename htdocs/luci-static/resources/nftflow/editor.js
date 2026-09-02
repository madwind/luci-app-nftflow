'use strict';
'require baseclass';
'require ui';
'require nftflow.ui as nftflowUi';

var MAX_EDITOR_BYTES = 32 * 1024;

function editorByteLength(value) {
    return nftflowUi.byteLength(value);
}

function createEditor(options) {
    options = options || {};

    var id = options.id || 'nftflow-editor';
    var label = options.label || _('Text editor');
    var maxBytes = Number(options.maxBytes) || MAX_EDITOR_BYTES;
    var minHeight = options.minHeight || '24em';
    var rows = options.rows || 24;
    var savedValue = String(options.value === undefined || options.value === null ? '' : options.value);
    var lineNumbers = E('textarea', {
        'class': 'cbi-input-text',
        'style': 'display: block; flex: 0 0 auto; width: 4em; min-height: ' + minHeight + '; box-sizing: border-box; overflow: hidden; resize: none; text-align: right; user-select: none;',
        'rows': rows,
        'wrap': 'off',
        'readonly': true,
        'tabindex': '-1',
        'aria-hidden': 'true'
    });
    var textarea = E('textarea', {
        'id': id,
        'class': 'cbi-input-text',
        'style': 'display: block; flex: 1 1 auto; width: 0; min-width: 0; min-height: ' + minHeight + '; box-sizing: border-box;',
        'rows': rows,
        'wrap': 'off',
        'spellcheck': 'false',
        'autocapitalize': 'off',
        'autocomplete': 'off',
        'readonly': options.readonly ? true : null,
        'aria-label': label
    });
    var editorPane = E('div', {
        'style': 'display: flex; align-items: stretch; gap: .25rem; width: 100%;'
    }, [ lineNumbers, textarea ]);
    var byteCount = E('span', {}, nftflowUi.formatBytes(editorByteLength(savedValue)));
    var byteLimit = E('span', { 'aria-live': 'polite' });
    var state = E('span', { 'aria-live': 'polite' }, options.readonly ? _('Read-only') : _('Saved file'));
    var leftActions = E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: .5rem;' });
    var rightActions = E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: .5rem; margin-left: auto;' });
    var toolbar = E('div', {
        'class': 'cbi-page-actions',
        'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .75rem;'
    }, [ leftActions, rightActions ]);
    var hasActions = !options.readonly && [
        options.format,
        options.check,
        options.loadDefault,
        options.reload,
        options.apply,
        options.applySave
    ].some(function(handler) {
        return typeof handler === 'function';
    });
    var rootChildren = [
        E('label', { 'class': 'cbi-section-descr', 'for': id }, label),
        editorPane,
        E('div', { 'class': 'cbi-section-descr' }, [
            _('Size'), ': ', byteCount, ' / ', nftflowUi.formatBytes(maxBytes), ' · ', state, ' ', byteLimit
        ])
    ];
    var api;

    if (hasActions)
        rootChildren.push(toolbar);

    var root = E('div', { 'class': 'nftflow-editor' }, rootChildren);
    textarea.value = savedValue;

    function updateLineNumbers() {
        var count = textarea.value === '' ? 1 : textarea.value.split('\n').length;
        var values = [];

        for (var index = 1; index <= count; index++)
            values.push(index);

        lineNumbers.value = values.join('\n');
        lineNumbers.style.width = Math.max(4, String(count).length + 2) + 'ch';
        lineNumbers.scrollTop = textarea.scrollTop;
    }

    function isDirty() {
        return textarea.value !== savedValue;
    }

    function updateState() {
        var bytes = editorByteLength(textarea.value);

        updateLineNumbers();
        nftflowUi.setText(byteCount, nftflowUi.formatBytes(bytes));
        nftflowUi.setText(state, options.readonly ? _('Read-only') : isDirty() ? _('Unsaved edits') : _('Saved file'));

        if (bytes > maxBytes) {
            nftflowUi.setState(byteLimit, 'error', _('%s maximum; current size is %s.').format(
                nftflowUi.formatBytes(maxBytes), nftflowUi.formatBytes(bytes)
            ));
        } else {
            nftflowUi.setState(byteLimit, '', '');
        }
    }

    function handleInput() {
        updateState();
        if (options.onInput)
            options.onInput(api);
    }

    function handleScroll() {
        lineNumbers.scrollTop = textarea.scrollTop;
    }

    function confirmAction(title, message, handler) {
        return new Promise(function(resolve, reject) {
            ui.showModal(title, [
                E('p', { 'class': 'alert-message warning' }, message),
                E('div', { 'class': 'right' }, [
                    E('button', {
                        'class': 'btn',
                        'type': 'button',
                        'click': function() {
                            ui.hideModal();
                            resolve(false);
                        }
                    }, _('Cancel')),
                    ' ',
                    E('button', {
                        'class': 'btn cbi-button cbi-button-negative',
                        'type': 'button',
                        'click': function() {
                            ui.hideModal();
                            Promise.resolve().then(handler).then(resolve, reject);
                        }
                    }, title)
                ])
            ]);
        });
    }

    function addInjectedAction(container, title, className, handler, confirmMessage) {
        if (typeof handler !== 'function')
            return null;

        var button = E('button', {
            'class': 'btn cbi-button ' + className,
            'type': 'button'
        }, title);
        var actionHandler = function() {
            if (confirmMessage)
                return confirmAction(title, confirmMessage, function() { return handler(api); });
            return Promise.resolve(handler(api));
        };

        button.addEventListener('click', ui.createHandlerFn(button, actionHandler));
        container.appendChild(button);
        return button;
    }

    function setValue(value) {
        textarea.value = String(value === undefined || value === null ? '' : value);
        updateState();
    }

    function markSaved(value) {
        if (value !== undefined)
            textarea.value = String(value === null ? '' : value);
        savedValue = textarea.value;
        updateState();
    }

    function withinLimit() {
        return editorByteLength(textarea.value) <= maxBytes;
    }

    function focus() {
        textarea.focus();
    }

    api = {
        byteLength: function() { return editorByteLength(textarea.value); },
        focus: focus,
        getValue: function() { return textarea.value; },
        isDirty: isDirty,
        markSaved: markSaved,
        maxBytes: maxBytes,
        root: root,
        setValue: setValue,
        textarea: textarea,
        update: updateState,
        withinLimit: withinLimit
    };

    addInjectedAction(leftActions, _('Format'), 'cbi-button-action', options.format, null);
    addInjectedAction(leftActions, _('Check syntax'), 'cbi-button-action', options.check, null);
    addInjectedAction(leftActions, _('Reload saved file'), 'cbi-button-negative', options.reload,
        _('Reload the saved file? This will replace the current editor contents. Any unsaved changes will be lost.'));
    addInjectedAction(leftActions, _('Load default'), 'cbi-button-negative', options.loadDefault,
        _('Load the default template? This will replace the current editor contents. Any unsaved changes will be lost.'));
    addInjectedAction(rightActions, _('Apply'), 'cbi-button-apply', options.apply, null);
    addInjectedAction(rightActions, _('Apply & Save'), 'cbi-button-save', options.applySave, null);

    textarea.addEventListener('input', handleInput);
    textarea.addEventListener('scroll', handleScroll);
    updateState();

    api.destroy = function() {
        textarea.removeEventListener('input', handleInput);
        textarea.removeEventListener('scroll', handleScroll);
    };

    return api;
}

return baseclass.extend({
    MAX_EDITOR_BYTES: MAX_EDITOR_BYTES,
    byteLength: editorByteLength,
    create: createEditor
});
