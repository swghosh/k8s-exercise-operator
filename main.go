package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	kubeinformers "k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/leaderelection"
	rl "k8s.io/client-go/tools/leaderelection/resourcelock"
	"k8s.io/klog/v2"

	clientset "github.com/swghosh/k8s-exercise-operator/pkg/generated/clientset/versioned"
	informers "github.com/swghosh/k8s-exercise-operator/pkg/generated/informers/externalversions"
)

var (
	masterURL  string
	kubeconfig string
)

const resyncPeriod = time.Minute * 2

var (
	lockName      = "k8s-exercise-operator-lock"
	lockNamespace = "default"

	// identity is "<PID>-<HOSTNAME>", env var $HOSTNAME provides name of the pod.
	identity = fmt.Sprintf("%d-%s", os.Getpid(), os.Getenv("HOSTNAME"))
)

var onlyOneSignalHandler = make(chan struct{})
var shutdownSignals = []os.Signal{os.Interrupt, syscall.SIGTERM}

func main() {
	klog.InitFlags(nil)
	flag.Parse()

	// set up signals so we handle the shutdown signal gracefully
	ctx := SetupSignalHandler()
	logger := klog.FromContext(ctx)

	cfg, err := clientcmd.BuildConfigFromFlags(masterURL, kubeconfig)
	if err != nil {
		logger.Error(err, "Error building kubeconfig")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	kubeClient, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "Error building kubernetes clientset")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	myClient, err := clientset.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "Error building kubernetes clientset")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	// Create a lease-based lock for leader election
	lock, err := rl.NewFromKubeconfig(
		rl.LeasesResourceLock,
		lockNamespace,
		lockName,
		rl.ResourceLockConfig{
			Identity: identity,
		},
		cfg,
		time.Second*10,
	)
	if err != nil {
		logger.Error(err, "Error creating resource lock")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	// Start the leader election loop; only the leader runs the controller
	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		LeaseDuration: time.Second * 15,
		RenewDeadline: time.Second * 10,
		RetryPeriod:   time.Second * 2,

		Lock: lock,
		Name: lockName,

		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: controllerStartupFunc(kubeClient, myClient, logger),
			OnStoppedLeading: func() {
				logger.Info("Leader election lost")
				klog.FlushAndExit(klog.ExitFlushTimeout, 1)
			},
			OnNewLeader: func(id string) {
				logger.Info("New leader elected", "identity", id)
			},
		},
	})
}

func controllerStartupFunc(kubeClient kubernetes.Interface, myClient clientset.Interface, logger klog.Logger) func(context.Context) {
	return func(ctx context.Context) {
		kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, resyncPeriod)
		myInformerFactory := informers.NewSharedInformerFactory(myClient, resyncPeriod)

		controller := NewController(ctx, kubeClient, myClient,
			kubeInformerFactory.Apps().V1().Deployments(),
			myInformerFactory.Cache().V1alpha1().Memcacheds())

		kubeInformerFactory.Start(ctx.Done())
		myInformerFactory.Start(ctx.Done())

		if err := controller.Run(ctx, 2); err != nil {
			logger.Error(err, "Error running controller")
			klog.FlushAndExit(klog.ExitFlushTimeout, 1)
		}
	}
}

func init() {
	flag.StringVar(&kubeconfig, "kubeconfig", "", "Path to a kubeconfig. Only required if out-of-cluster.")
	flag.StringVar(&masterURL, "master", "", "The address of the Kubernetes API server. Overrides any value in kubeconfig. Only required if out-of-cluster.")
}

// SetupSignalHandler registered for SIGTERM and SIGINT. A context is returned
// which is cancelled on one of these signals. If a second signal is caught,
// the program is terminated with exit code 1.
func SetupSignalHandler() context.Context {
	close(onlyOneSignalHandler) // panics when called twice

	c := make(chan os.Signal, 2)
	ctx, cancel := context.WithCancel(context.Background())
	signal.Notify(c, shutdownSignals...)
	go func() {
		<-c
		cancel()
		<-c
		os.Exit(1) // second signal. Exit directly.
	}()

	return ctx
}
