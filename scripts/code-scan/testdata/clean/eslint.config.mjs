import js from '@eslint/js';

export default [
  js.configs.recommended,
  {
    files: ['**/*.{js,mjs,ts}'],
    rules: {
      'no-unused-vars': 'warn',
      eqeqeq: 'error',
    },
  },
];
