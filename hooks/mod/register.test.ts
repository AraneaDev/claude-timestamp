import { expect, test } from 'claude-code/testing'

test('the module loads and passes a session start through', async ($, on) => {
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await expect($.session.start({ cwd: '/w', surface: null, isInteractive: true })).resolves.toEqual({ cwd: '/w' })
})
