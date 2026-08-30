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
    var savedValue = String(options.value === undefined || options.value === null ? '' : options.value);
    var textarea = E('textarea', {
        'id': id,
        'class': 'cbi-input-text',
        'style': 'display: block; width: 100%; min-height: ' + (options.minHeight || '24em') + '; box-sizing: border-box;',
        'rows': options.rows || 24,
        'wrap': 'off',
        'spellcheck': 'false',
        'autocapitalize': 'off',
        'autocomplete': 'off',
        'readonly': options.readonly ? true : null,
        'aria-label': label
    });
    var byteCount = E('span', {}, nftflowUi.formatBytes(editorByteLength(savedValue)));
    var byteLimit = E('span', { 'aria-live': 'polite' });
    var state = E('span', { 'aria-live': 'polite' }, options.readonly ? _('Read-only') : _('Saved file'));
    var leftActions = E('div', {
        'style': 'display: flex; flex-wrap: wrap; gap: .5rem;'
    });
    var rightActions = E('div', {
        'style': 'display: flex; flex-wrap: wrap; gap: .5rem; margin-left: auto;'
    });
    var toolbar = E('div', {
        'class': 'cbi-page-actions',
        'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .75rem;'
    }, [ leftActions, rightActions ]);
    var hasActions = !options.readonly && [
        options.format,
        options.check,
        options.reload,
        options.apply,
        options.applySave
    ].some(function(handler) {
        return typeof handler === 'function';
    });
    var rootChildren = [
        E('label', { 'class': 'cbi-section-descr', 'for': id }, label),
        textarea,
        E('div', { 'class': 'cbi-section-descr' }, [
            _('Size'), ': ', byteCount, ' / ', nftflowUi.formatBytes(maxBytes), ' · ', state, ' ', byteLimit
        ])
    ];
    var api;

    if (hasActions)
        rootChildren.push(toolbar);

    var root = E('div', { 'class': 'nftflow-editor' }, rootChildren);
    textarea.value = savedValue;

    function isDirty() {
        return textarea.value !== savedValue;
    }

    function updateState() {
        var bytes = editorByteLength(textarea.value);

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

    function confirmDiscard() {
        return !isDirty() || window.confirm(_('Discard unsaved changes and reload the saved file?'));
    }

    function addInjectedAction(container, title, className, handler, confirmReload) {
        if (typeof handler !== 'function')
            return null;

        var button = E('button', {
            'class': 'btn cbi-button ' + className,
            'type': 'button'
        }, title);
        var actionHandler = function() {
            if (confirmReload && !confirmDiscard())
                return Promise.resolve(false);
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

    addInjectedAction(leftActions, _('Format'), 'cbi-button-action', options.format, false);
    addInjectedAction(leftActions, _('Check syntax'), 'cbi-button-action', options.check, false);
    addInjectedAction(leftActions, _('Reload saved file'), 'cbi-button-action', options.reload, true);
    addInjectedAction(rightActions, _('Apply'), 'cbi-button-apply', options.apply, false);
    addInjectedAction(rightActions, _('Apply & Save'), 'cbi-button-save', options.applySave, false);

    textarea.addEventListener('input', handleInput);
    updateState();

    api.destroy = function() {
        textarea.removeEventListener('input', handleInput);
    };

    return api;
}

return baseclass.extend({
    MAX_EDITOR_BYTES: MAX_EDITOR_BYTES,
    byteLength: editorByteLength,
    create: createEditor
});
