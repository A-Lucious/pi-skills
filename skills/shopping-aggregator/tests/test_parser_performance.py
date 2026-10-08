from shopping_aggregator.providers import get_provider


def test_taobao_extractor_handles_large_page_without_cross_card_backtracking():
    card = '<div class="title--ASSt27UY " title="佳能r50照相机"></div><div class="priceInt--yqqZMJ5a">7320</div>'
    html = ("x" * 1000 + card) * 100
    items = get_provider("taobao").extract(html, limit=5)
    assert len(items) == 5
