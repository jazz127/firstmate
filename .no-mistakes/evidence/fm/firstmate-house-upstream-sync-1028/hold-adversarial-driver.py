import pathlib
root=pathlib.Path.cwd(); source=(pathlib.Path(__file__).resolve().parent/'local-product-driver.py').read_text()
exec(source[:source.index('try:\n')])
lines=(E/'local-product-transcript.txt').read_text().splitlines(); results=json.loads((E/'local-product-results.json').read_text())
h=W/'hold-home'; conf=h/'.tasks.toml'
encoded=conf.read_text(); conf.write_text(encoded.replace('"data/review\\u0023\\U000000e9.md" # escaped reader path',"'data/review#é.md'"))
try:
    run(h,['tasks-axi','add','unanswered-review','Review unanswered','--kind','scout','--repo','sample','--start'])
    (h/'data/unanswered-review').mkdir(); (h/'data/unanswered-review/report.md').write_text('# Review\nUnanswered choice.\n')
    (h/'state/unanswered-review.meta').write_text('window=unused:unanswered-review\nkind=scout\nmode=scout\nspawn_gen=fixture-unanswered\n')
    (h/'state/unanswered-review.status').write_text('done: report complete\n')
    run(h,[R/'bin/fm-captain-hold.sh','hold','unanswered-call','--title','Unanswered choice','--reason','pending choice','--repo','sample','--origin','unanswered-review'])
    run(h,[R/'bin/fm-captain-hold.sh','complete','unanswered-review','unanswered-call'])
    run(h,['tasks-axi','done','unanswered-call'])
    conf.write_text(encoded)
    out=run(h,[R/'bin/fm-captain-hold.sh','verify','unanswered-review'],expected=1)
    assert 'unanswered-call' in out
    assert (h/'state/unanswered-review.meta').exists()
    log('OBSERVED: archived out-of-band close without a recorded decision is refused; origin metadata remains')
finally:
    (E/'local-product-transcript.txt').write_text('\n'.join(lines)+'\n')
