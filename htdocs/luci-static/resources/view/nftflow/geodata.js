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
    params: [ 'kind', 'query', 'mode', 'regex', 'sensitive', 'group', 'position', 'within' ],
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
        var cancelButton = button(_('Cancel'), false);
        cancelButton.hidden = true;
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
            searchButton, cancelButton
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
            var visible = filtered.slice(0, 160);
            var nodes = visible.map(function(category) {
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
            });
            if (!filtered.length)
                nodes.push(E('div', {}, _('No categories found.')));
            else if (filtered.length > visible.length)
                nodes.push(E('p', { 'style': 'opacity:.7; margin:.5rem 0;' },
                    _('Showing first %s of %s categories. Use the filter to narrow results.').format(
                        visible.length, filtered.length)));
            categoryList.replaceChildren.apply(categoryList, nodes);
        }
        function browse() {
            if (!selected) return Promise.resolve();
            var id = ++pending;
            searchButton.disabled = false;
            cancelButton.hidden = true;
            ruleControls.hidden = false;
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
            var input = query.value.trim();
            if (!input) return;

            var id = ++pending;
            var cursor = { group: '0', position: '0', within: '0' };
            var groups = [], byName = Object.create(null), allNames = Object.create(null);
            var totalMatches = 0, categoryCount = 0, skippedRegex = 0;
            var finished = false, percent = 0;

            selected = null;
            renderCategories();
            title.textContent = _('Global search');
            ruleControls.hidden = true;
            body.replaceChildren(E('p', {}, _('Searching the GeoData file...')));
            searchButton.disabled = true;
            cancelButton.hidden = false;

            function renderProgress() {
                var nodes = [
                    E('p', {}, _('%s matching rules in %s categories').format(totalMatches, categoryCount))
                ];
                if (!finished)
                    nodes.push(E('p', { 'style': 'opacity:.7;' },
                        _('Searching... %s%').format(percent)));
                if (categoryCount > groups.length)
                    nodes.push(E('p', { 'class': 'warning' },
                        _('Showing only the first 80 matching categories.')));
                if (skippedRegex)
                    nodes.push(E('p', {},
                        _('%s regex rules were not evaluated for domain matching.').format(
                            skippedRegex)));

                groups.forEach(function(group) {
                    nodes.push(E('h4', { 'style': 'margin-bottom:.3rem;' },
                        group.name + ' (' + group.total + ')' +
                        (group.inverse ? ' [inverse]' : '')));
                    nodes.push(resultsTable(group.matches));
                    var open = button(_('Browse category'), false);
                    open.style.marginBottom = '.8rem';
                    open.onclick = function() {
                        selected = group.name;
                        page = 0;
                        ruleFilter.value = '';
                        ruleType.value = 'all';
                        renderCategories();
                        browse();
                    };
                    nodes.push(open);
                });
                if (finished && !groups.length)
                    nodes.push(E('p', {}, _('No matches found.')));
                body.replaceChildren.apply(body, nodes);
            }

            function finish() {
                if (id !== pending) return;
                finished = true;
                searchButton.disabled = false;
                cancelButton.hidden = true;
                renderProgress();
                nftflowUi.setState(state, 'ok', '');
            }

            function searchNext() {
                if (id !== pending) return Promise.resolve();
                return callSearch(kind.value, input, mode.value,
                    regex.checked ? '1' : '0', sensitive.checked ? '1' : '0',
                    cursor.group, cursor.position, cursor.within).then(check).then(function(result) {
                    if (id !== pending) return;

                    totalMatches += result.total || 0;
                    skippedRegex += result.skipped_regex || 0;
                    (result.categories || []).forEach(function(item) {
                        if (!allNames[item.name]) {
                            allNames[item.name] = true;
                            categoryCount++;
                        }
                        var group = byName[item.name];
                        if (!group && groups.length < 80) {
                            group = { name: item.name, total: 0, inverse: !!item.inverse, matches: [] };
                            groups.push(group);
                            byName[item.name] = group;
                        }
                        if (!group) return;
                        group.total += item.total || 0;
                        (item.matches || []).forEach(function(entry) {
                            if (group.matches.length < 8) group.matches.push(entry);
                        });
                    });

                    percent = Math.min(100, Math.floor((result.progress || 0) * 100));
                    if (result.done === true) {
                        finish();
                        return;
                    }

                    var next = {
                        group: String(result.next_group),
                        position: String(result.next_position),
                        within: String(result.next_within || '0')
                    };
                    if (next.group === cursor.group && next.position === cursor.position)
                        throw new Error(_('GeoData search did not advance.'));
                    cursor = next;
                    busy(_('Searching... %s%').format(percent));
                    renderProgress();
                    return searchNext();
                });
            }

            busy(_('Searching... 0%'));
            return searchNext().catch(function(error) {
                if (id !== pending) return;
                searchButton.disabled = false;
                cancelButton.hidden = true;
                body.replaceChildren(E('p', { 'class': 'error' },
                    _('Search failed. Previous category results were cleared.')));
                showError(error);
            });
        }
        function loadCategories() {
            var id = ++pending;
            searchButton.disabled = false;
            cancelButton.hidden = true;
            selected = null;
            categories = [];
            page = 0;
            previous.disabled = true;
            next.disabled = true;
            pageInfo.textContent = '';
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
            sensitive.disabled = mode.value !== 'text';
            if (regex.disabled) regex.checked = false;
            if (sensitive.disabled) sensitive.checked = false;
        }
        mode.onchange = updateMode;
        kind.onchange = function() { loadCategories(); };
        searchButton.onclick = runSearch;
        cancelButton.onclick = function() {
            ++pending;
            searchButton.disabled = false;
            cancelButton.hidden = true;
            nftflowUi.setState(state, 'notice', _('Search cancelled. Partial results are displayed.'));
        };
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
