from shopping_aggregator.providers import get_provider


GOOFISH_CARD = """<a class="feeds-item-wrap--rGdH_KoF" href="https://www.goofish.com/item?id=1058903242244&amp;categoryId=126864782"><img class="feeds-image--TDRC4fV1" src="//img.alicdn.com/item.webp"><div class="row1-wrap-title--qIlOySTh" title="佳能EOS R50微单套机"><span class="main-title--sMrtWSJa">佳能EOS R50微单套机</span></div><div class="row3-wrap-price--IZmX7M0K"><span class="sign--x6uVdG3X">¥</span><span class="number--NKh1vXWM">4255</span><span class="decimal--lSAcITCN">.00</span></div><div class="seller-text-wrap--yZYFxBkK" title="河南"><p class="seller-text--Rr2Y3EbB">河南</p></div></a>"""


def test_goofish_extracts_feeds_item_cards():
    items = get_provider("goofish").extract(GOOFISH_CARD)
    assert items[0].title == "佳能EOS R50微单套机"
    assert (
        items[0].url
        == "https://www.goofish.com/item?id=1058903242244&categoryId=126864782"
    )
    assert items[0].price == "4255.00"
    assert items[0].location == "河南"
    assert items[0].image == "https://img.alicdn.com/item.webp"
