'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require nftflow.ui as nftflowUi';

var callList = rpc.declare({
    object: 'luci.nftflow', method: 'geodata_list', params: [ 'kind' ],
    expect: { '': {} }, reject: true
});
var callBrowse = rpc.declare({
    object: 'luci.nftflow', method: 'geodata_browse',
    params: [ 'kind', 'category', 'page', 'filter', 'entry_type' ],
    expect: { '': {} }, reject: true
});
var callSearch = rpc.declare({
    object: 'luci.nftflow', method: 'geodata_search',
    params: [ 'kind', 'query', 'mode', 'regex', 'sensitive' ],
    expect: { '': {} }, reject: true
});

function field(label, node) {
    return E('label', { 'style': 'display:flex; flex-direction:column; gap:.3rem; min-width:0;' }, [
        E('span', { 'style': 'font-size:.9em;' }, label), node
    ]);
}
function choose(values) {
    return E('select', { 'class': 'cbi-input-select' },
        values.map(function(v) { return E('option', { value: v[0] }, v[1]); }));
}
function button(text, action) {
    return E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-' + (action ? 'action' : 'neutral') }, text);
}
function entryRow(entry) {
    var attrs = Array.isArray(entry.attributes) ? entry.attributes : [];
    return E('tr', {}, [
        E('td', {}, E('code', {}, entry.type || '')),
        E('td', { 'style': 'overflow-wrap:anywhere;' }, E('code', {}, entry.value || '')),
        E('td', { 'style': 'overflow-wrap:anywhere;' }, attrs.join(', ') || '\u2014')
    ]);
}
function resultsTable(entries) {
    return E('div', { 'style': 'overflow-x:auto;' }, E('table', {
        'class': 'table', 'style': 'width:100%;'
    }, [
        E('thead', {}, E('tr', {}, [
            E('th', {}, _('Type')), E('th', {}, _('Value')), E('th', {}, _('Attributes'))
        ])),
        E('tbody', {}, (entries || []).length
            ? entries.map(entryRow)
            : [ E('tr', {}, E('td', { colspan: 3 }, _('No matching entries.'))) ])
    ]));
}
function check(result) { return nftflowUi.requireOk(result, _('GeoData request failed.')); }

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() { return uci.load('nftflow'); },

    render: function() {
        document.title = _('NftFlow | GeoData');

        var kind = choose([ [ 'geosite', 'GeoSite' ], [ 'geoip', 'GeoIP' ] ]);
        var query = E('input', {
            'type': 'search', 'class': 'cbi-input-text', 'style': 'min-width:12rem; flex:1;',
            'placeholder': 'www.youtube.com', 'autocomplete': 'off', 'spellcheck': 'false'
        });
        var mode = choose([ [ 'match', _('Match rules') ], [ 'text', _('Search text') ] ]);
        var regex = E('input', { 'type': 'checkbox' });
        var sensitive = E('input', { 'type': 'checkbox' });
        var searchButton = button(_('Search'), true);
        var categoryFilter = E('input', {
            'type': 'search', 'class': 'cbi-input-text',
            'placeholder': _('Filter categories'), 'style': 'width:100%; box-sizing:border-box;'
        });
        var categoryList = E('div', { 'style': 'max-height:32rem; overflow-y:auto;' });
        var ruleFilter = E('input', {
            'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Filter entries'),
            'style': 'min-width:8rem; flex:1;'
        });
        var ruleType = choose([
            [ 'all', _('All types') ], [ 'domain', 'domain' ], [ 'full', 'full' ],
            [ 'keyword', 'keyword' ], [ 'regexp', 'regexp' ], [ 'cidr', 'cidr' ]
        ]);
        var previous = button(_('Previous'), false);
        var next = button(_('Next'), false);
        var body = E('div', {}, _('Select a category to view its rules.'));
        var pageInfo = E('span', { 'style': 'opacity:.75;' });
        var title = E('h3', { 'style': 'margin:.2rem 0;' }, _('Rules'));
        var fileInfo = E('div', { 'style': 'opacity:.75; overflow-wrap:anywhere;' });
        var state = E('div', { 'aria-live': 'polite' });
        var categories = [];
        var selected = null, page = 0, total = 0, pending = 0;

        var controls = E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.65rem; align-items:end;' }, [
            field(_('Dataset'), kind),
            field(_('Mode'), mode),
            field(_('Query'), query),
            field(_('Regex'), regex),
            field(_('Case sensitive'), sensitive),
            searchButton
        ]);

        var ruleControls = E('div', {
            'style': 'display:flex; flex-wrap:wrap; gap:.5rem; align-items:center; margin:.6rem 0;'
        }, [ ruleFilter, ruleType, previous, pageInfo, next ]);

        var main = E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:1rem; align-items:stretch;' }, [
            E('section', { 'class': 'cbi-section', 'style': 'flex:1 1 14rem; min-width:0; max-width:100%;' }, [
                E('h3', { 'style': 'margin-top:0;' }, _('Categories')),
                categoryFilter, categoryList
            ]),
            E('section', { 'class': 'cbi-section', 'style': 'flex:3 1 28rem; min-width:0;' }, [
                title, ruleControls, body
            ])
        ]);

        function showError(error) {
            nftflowUi.setState(state, 'error', nftflowUi.errorMessage(error));
        }
        function busy(text) {
            nftflowUi.setState(state, 'notice', text);
        }
        function renderCategories() {
            var filter = categoryFilter.value.trim().toLowerCase();
            var filtered = categories.filter(function(category) {
                return category.name.indexOf(filter) >= 0;
            });
            categoryList.replaceChildren.apply(categoryList, filtered.length
                ? filtered.map(function(category) {
                    var active = selected === category.name;
                    var item = button(category.name + ' (' + category.count + ')' +
                        (category.inverse ? ' [inverse]' : ''), active);
                    item.style.display = 'block';
                    item.style.width = '100%';
                    item.style.textAlign = 'left';
                    item.style.margin = '.18rem 0';
                    item.onclick = function() {
                        selected = category.name;
                        page = 0;
                        ruleFilter.value = '';
                        ruleType.value = 'all';
                        renderCategories();
                        browse();
                    };
                    return item;
                })
                : [ E('div', {}, _('No categories found.')) ]);
        }
        function browse() {
            if (!selected) return Promise.resolve();
            var id = ++pending;
            busy(_('Loading rules...'));
            title.textContent = kind.value.toUpperCase() + ' / ' + selected;
            return callBrowse(kind.value, selected, String(page),
                ruleFilter.value.trim(), ruleType.value).then(check).then(function(result) {
                if (id !== pending) return;
                total = result.total || 0;
                var count = Array.isArray(result.entries) ? result.entries.length : 0;
                body.replaceChildren(resultsTable(result.entries));
                previous.disabled = page === 0;
                next.disabled = (page + 1) * 100 >= total;
                pageInfo.textContent = total
                    ? _('%s\u2013%s of %s').format(page * 100 + 1, page * 100 + count, total)
                    : _('0 results');
                nftflowUi.setState(state, 'ok', '');
            }).catch(function(error) { if (id === pending) showError(error); });
        }
        function runSearch() {
            if (!query.value.trim()) return;
            var id = ++pending;
            busy(_('Searching data file...'));
            selected = null;
            renderCategories();
            title.textContent = _('Global search');
            ruleControls.hidden = true;
            return callSearch(kind.value, query.value.trim(), mode.value,
                regex.checked ? '1' : '0', sensitive.checked ? '1' : '0').then(check).then(function(result) {
                if (id !== pending) return;
                var groups = Array.isArray(result.categories) ? result.categories : [];
                var nodes = [
                    E('p', {}, _('%s matching rules in %s categories').format(
                        result.total || 0, result.category_total || 0))
                ];
                if (result.truncated)
                    nodes.push(E('p', { 'class': 'warning' }, _('Showing only the first 80 categories.')));
                if (result.skipped_regex)
                    nodes.push(E('p', {}, _('%s regex rules were not evaluated for domain matching.').format(
                        result.skipped_regex)));
                groups.forEach(function(group) {
                    var heading = E('h4', { 'style': 'margin-bottom:.3rem;' },
                        group.name + ' (' + group.total + ')' + (group.inverse ? ' [inverse]' : ''));
                    nodes.push(heading, resultsTable(group.matches));
                    var open = button(_('Browse category'), false);
                    open.style.marginBottom = '.8rem';
                    open.onclick = function() {
                        selected = group.name;
                        ruleControls.hidden = false;
                        ruleFilter.value = '';
                        ruleType.value = 'all';
                        page = 0;
                        renderCategories();
                        browse();
                    };
                    nodes.push(open);
                });
                if (!groups.length) nodes.push(E('div', {}, _('No matches found.')));
                body.replaceChildren.apply(body, nodes);
                nftflowUi.setState(state, 'ok', '');
            }).catch(function(error) { if (id === pending) showError(error); });
        }
        function loadCategories() {
            var id = ++pending;
            selected = null;
            categories = [];
            body.replaceChildren(_('Select a category to view its rules.'));
            ruleControls.hidden = false;
            title.textContent = _('Rules');
            categoryList.replaceChildren();
            query.placeholder = kind.value === 'geoip' ? '1.1.1.1' : 'www.youtube.com';
            busy(_('Loading categories...'));
            return callList(kind.value).then(check).then(function(result) {
                if (id !== pending) return;
                categories = result.categories || [];
                fileInfo.textContent = result.path + ' \u00b7 ' +
                    nftflowUi.formatBytes(result.size) + ' \u00b7 ' +
                    categories.length + ' ' + _('categories');
                renderCategories();
                nftflowUi.setState(state, 'ok', '');
            }).catch(function(error) {
                if (id !== pending) return;
                fileInfo.textContent = '';
                showError(error);
            });
        }

        function updateMode() {
            regex.disabled = mode.value !== 'text';
            if (regex.disabled) regex.checked = false;
        }
        mode.onchange = updateMode;
        kind.onchange = function() { loadCategories(); };
        searchButton.onclick = runSearch;
        query.onkeydown = function(event) { if (event.key === 'Enter') runSearch(); };
        categoryFilter.oninput = renderCategories;
        ruleFilter.onkeydown = function(event) {
            if (event.key === 'Enter') { page = 0; browse(); }
        };
        ruleType.onchange = function() { page = 0; browse(); };
        previous.onclick = function() { if (page > 0) { page--; browse(); } };
        next.onclick = function() { if ((page + 1) * 100 < total) { page++; browse(); } };
        updateMode();

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('GeoData Explorer')),
            E('p', {}, _('Browse and search local GeoSite / GeoIP DAT files without modifying firewall rules.')),
            E('div', { 'class': 'cbi-section' }, [ controls, fileInfo, state ]),
            main
        ]);
        loadCategories();
        return root;
    }
});
