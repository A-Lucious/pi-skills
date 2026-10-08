from shopping_aggregator.providers import get_provider


def test_jd_extracts_product_cards_from_html():
    html = """<div class="gl-i-wrap"><a href="//item.jd.com/123.html"><em>ThinkPad 笔记本</em></a><strong><i>5999.00</i></strong><span class="curr-shop">京东自营</span></div>"""
    provider = get_provider("jd")
    items = provider.extract(html)
    assert items[0].title == "ThinkPad 笔记本"
    assert items[0].price == "5999.00"
    assert items[0].url == "https://item.jd.com/123.html"
    assert items[0].shop == "京东自营"


def test_goofish_extracts_embedded_json_items():
    html = '{"title":"iPhone 15","price":"4500","itemUrl":"https://www.goofish.com/item?id=1","nick":"卖家A"}'
    provider = get_provider("goofish")
    items = provider.extract(html)
    assert items[0].site == "goofish"
    assert items[0].title == "iPhone 15"


def test_login_required_detects_login_markers():
    provider = get_provider("taobao")
    assert provider.login_required("请登录后继续访问") is True
    assert provider.login_required("<div>商品列表</div>") is False
