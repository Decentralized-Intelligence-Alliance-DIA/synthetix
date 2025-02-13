const path = require('path');
const isCI = require('is-ci');

const {
	constants: { BUILD_FOLDER },
} = require('../..');
const { task } = require('hardhat/config');
const {
	compileInstance,
	prepareDeploy,
	deployInstance,
	connectInstances,
} = require('../../test/integration/utils/deploy');

const synthsToAdd = [{ name: 'sREDEEMER', asset: 'USD' }];

task('test:integration:l1', 'run isolated layer 1 production tests')
	.addFlag('compile', 'Compile an l1 instance before running the tests')
	.addFlag('deploy', 'Deploy an l1 instance before running the tests')
	.addFlag('useSips', 'Use sources from SIPs directly, instead of releases')
	.addFlag('useFork', 'Run the tests against a fork of mainnet')
	.addOptionalParam(
		'providerPort',
		'The target port for the running local chain to test on',
		'8545'
	)
	.addOptionalParam('grep', 'test pattern to match (mocha)', '')
	.setAction(async (taskArguments, hre) => {
		hre.config.paths.tests = './test/integration/l1/';

		_commonIntegrationTestSettings({ hre, taskArguments });

		const providerUrl = (hre.config.providerUrl = 'http://127.0.0.1');
		const providerPort = (hre.config.providerPort = taskArguments.providerPort);
		const useOvm = false;
		const buildPath = path.join(__dirname, '..', '..', BUILD_FOLDER);

		if (taskArguments.compile) {
			await compileInstance({ useOvm, buildPath });
		}
		if (taskArguments.useFork) {
			hre.config.fork = true;
		}

		if (taskArguments.deploy) {
			if (taskArguments.useFork) {
				await prepareDeploy({
					network: 'mainnet',
					synthsToAdd,
					useOvm,
					useSips: taskArguments.useSips,
				});
				await deployInstance({
					addNewSynths: true,
					buildPath,
					freshDeploy: false,
					network: 'mainnet',
					providerPort,
					providerUrl,
					useFork: true,
					useOvm,
				});
			} else {
				await hre.run('cannon:build', { file: 'cannonfile.aggregator.toml' });
				await hre.run('cannon:build');
			}
			hre.config.addedSynths = synthsToAdd;
		}

		await hre.run('test', taskArguments);
	});

task('test:integration:l2', 'run isolated layer 2 production tests')
	.addFlag('debugOptimism', 'Debug Optimism activity')
	.addFlag('compile', 'Compile an l2 instance before running the tests')
	.addFlag('deploy', 'Deploy an l2 instance before running the tests')
	.addFlag('useSips', 'Use sources from SIPs directly, instead of releases')
	.addFlag('useFork', 'Run the tests against a fork of mainnet')
	.addOptionalParam(
		'providerPort',
		'The target port for the running local chain to test on',
		'8545'
	)
	.addOptionalParam('grep', 'test pattern to match (mocha)', '')
	.setAction(async (taskArguments, hre) => {
		hre.config.paths.tests = './test/integration/l2/';
		hre.config.debugOptimism = taskArguments.debugOptimism;

		_commonIntegrationTestSettings({ hre, taskArguments });

		const providerUrl = (hre.config.providerUrl = 'http://127.0.0.1');
		hre.config.providerPortL1 = '9545';
		const providerPortL2 = (hre.config.providerPortL2 = taskArguments.providerPort);
		const useOvm = true;
		const buildPath = path.join(__dirname, '..', '..', BUILD_FOLDER);

		if (taskArguments.compile) {
			await compileInstance({ useOvm, buildPath });
		}
		if (taskArguments.useFork) {
			hre.config.fork = true;
		}

		if (taskArguments.deploy) {
			if (taskArguments.useFork) {
				await prepareDeploy({
					network: 'mainnet',
					synthsToAdd,
					useOvm,
					useSips: taskArguments.useSips,
				});
				await deployInstance({
					addNewSynths: true,
					buildPath,
					freshDeploy: false,
					network: 'mainnet',
					providerPort: providerPortL2,
					providerUrl,
					useFork: true,
					useOvm,
				});
			} else {
				await hre.run('cannon:build', { file: 'cannonfile.aggregator.toml' });
				await hre.run('cannon:build', {
					file: 'cannonfile.optimism.toml',
					preset: 'optimism',
					options: ['network=optimism'],
				});
			}
			hre.config.addedSynths = synthsToAdd;
		}

		await hre.run('test', taskArguments);
	});

task('test:integration:dual', 'run integrated layer 1 and layer 2 production tests')
	.addFlag('debugOptimism', 'Debug Optimism activity')
	.addFlag('compile', 'Compile the l1 instance before running the tests')
	.addFlag('deploy', 'Deploy the l1 instance before running the tests')
	.setAction(async (taskArguments, hre) => {
		hre.config.paths.tests = './test/integration/dual/';
		hre.config.debugOptimism = taskArguments.debugOptimism;

		_commonIntegrationTestSettings({ hre, taskArguments });

		const providerUrl = (hre.config.providerUrl = 'http://localhost');
		const providerPortL1 = (hre.config.providerPortL1 = '9545');
		const providerPortL2 = (hre.config.providerPortL2 = '8545');
		const buildPath = path.join(__dirname, '..', '..', BUILD_FOLDER);

		if (taskArguments.compile) {
			await compileInstance({ useOvm: false, buildPath: buildPath });
		}

		if (taskArguments.deploy) {
			await deployInstance({
				useOvm: false,
				providerUrl,
				providerPort: providerPortL1,
				buildPath: buildPath,
			});

			await deployInstance({
				useOvm: true,
				providerUrl,
				providerPort: providerPortL2,
				buildPath: buildPath,
			});
		}

		await connectInstances({
			providerUrl,
			providerPortL1,
			providerPortL2,
			quiet: !taskArguments.debugOptimism,
		});

		await hre.run('test', taskArguments);
	});

function _commonIntegrationTestSettings({ hre, taskArguments }) {
	const timeout = 600000; // 10m
	hre.config.mocha.timeout = timeout;
	// stop on first error unless we're on CI
	hre.config.mocha.bail = !isCI;
	hre.config.networks.localhost.timeout = timeout;

	taskArguments.maxMemory = true;
	taskArguments.noCompile = true;

	if (taskArguments.grep) {
		hre.config.mocha.grep = taskArguments.grep;
	}
}
